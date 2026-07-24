require "./spec_helper"

module EncoderTableSizeSpec
  class FailingWriter < IO
    getter output = IO::Memory.new

    def initialize(@fail_on_write : Int32)
      @write_count = 0
    end

    def read(slice : Bytes) : Int32
      0
    end

    def write(slice : Bytes) : Nil
      @write_count += 1
      output.write(slice)
      if @write_count == @fail_on_write
        raise IO::Error.new("forced writer failure")
      end
    end
  end

  {% if flag?(:preview_mt) %}
    class BarrierWriter < IO
      getter output = IO::Memory.new

      def initialize(@started : Channel(Nil), @release : Channel(Nil))
        @blocked = false
      end

      def read(slice : Bytes) : Int32
        0
      end

      def write(slice : Bytes) : Nil
        output.write(slice)
        return if @blocked

        @blocked = true
        @started.send(nil)
        @release.receive
      end
    end
  {% end %}

  def self.resized_encoder(size = 0)
    encoder = HPack::Encoder.new
    encoder.resize_table(size)
    encoder
  end
end

describe HPack::Encoder do
  describe ".new" do
    it "rejects negative and unrepresentable table sizes" do
      expect_raises(ArgumentError, /table size/) do
        HPack::Encoder.new(max_table_size: -1)
      end
      expect_raises(ArgumentError, /table size/) do
        HPack::Encoder.new(max_table_size: Int64::MAX)
      end
      expect_raises(ArgumentError, /table size/) do
        HPack::Encoder.new(max_table_size: UInt32::MAX)
      end
      expect_raises(ArgumentError, /table size/) do
        HPack::Encoder.new(max_table_size: UInt64::MAX)
      end
    end

    it "accepts boundary sizes from any integer type" do
      HPack::Encoder.new(max_table_size: 0).table.maximum.should eq 0
      HPack::Encoder.new(max_table_size: 1024_u32).table.maximum.should eq 1024
    end
  end

  describe "#resize_table" do
    it "encodes boundary sizes with an empty field block" do
      encoder = HPack::Encoder.new
      encoder.resize_table(0)
      encoder.encode([] of Tuple(String, String)).should eq Bytes[0x20]

      encoder = HPack::Encoder.new
      encoder.resize_table(31_u32)
      encoder.encode([] of Tuple(String, String)).should eq Bytes[0x3f, 0x00]

      encoder = HPack::Encoder.new(max_table_size: 0)
      encoder.resize_table(4096)
      encoder.encode([] of Tuple(String, String)).should eq Bytes[0x3f, 0xe1, 0x1f]

      encoder = HPack::Encoder.new(max_table_size: 0)
      encoder.resize_table(Int32::MAX)
      encoded = encoder.encode([] of Tuple(String, String))
      encoded.should eq Bytes[
        0x3f, 0xe0, 0xff, 0xff, 0xff, 0x07,
      ]

      decoder = HPack::Decoder.new(0)
      decoder.max_table_size = Int32::MAX
      decoder.decode(encoded).should be_empty
      decoder.table.maximum.should eq Int32::MAX
    end

    it "rejects negative and unrepresentable sizes without changing state" do
      encoder = HPack::Encoder.new

      expect_raises(ArgumentError, /table size/) { encoder.resize_table(-1) }
      expect_raises(ArgumentError, /table size/) { encoder.resize_table(Int64::MAX) }
      expect_raises(ArgumentError, /table size/) { encoder.resize_table(UInt32::MAX) }
      expect_raises(ArgumentError, /table size/) { encoder.resize_table(UInt64::MAX) }

      encoder.table.maximum.should eq 4096
      encoder.encode([] of Tuple(String, String)).should be_empty
    end

    it "treats an unchanged size as a no-op" do
      encoder = HPack::Encoder.new

      encoder.resize_table(4096)

      encoder.encode([] of Tuple(String, String)).should be_empty
    end

    it "coalesces changes to the smallest and final sizes" do
      encoder = HPack::Encoder.new
      encoder.resize_table(1024)
      encoder.resize_table(2048)
      encoder.encode([] of Tuple(String, String)).should eq Bytes[
        0x3f, 0xe1, 0x07,
        0x3f, 0xe1, 0x0f,
      ]

      encoder = HPack::Encoder.new
      encoder.resize_table(2048)
      encoder.resize_table(1024)
      encoder.encode([] of Tuple(String, String)).should eq Bytes[
        0x3f, 0xe1, 0x07,
      ]

      encoder = HPack::Encoder.new
      encoder.resize_table(1024)
      encoder.resize_table(4096)
      encoder.encode([] of Tuple(String, String)).should eq Bytes[
        0x3f, 0xe1, 0x07,
        0x3f, 0xe1, 0x1f,
      ]
    end

    it "coalesces longer oscillations into no more than two updates" do
      encoder = HPack::Encoder.new

      [2048, 1024, 3072, 512, 2048].each do |size|
        encoder.resize_table(size)
      end

      encoder.encode([] of Tuple(String, String)).should eq Bytes[
        0x3f, 0xe1, 0x03,
        0x3f, 0xe1, 0x0f,
      ]
    end

    it "does not clear a pending update when the current size is requested" do
      encoder = HPack::Encoder.new

      encoder.resize_table(1024)
      encoder.resize_table(1024)

      encoder.encode([] of Tuple(String, String)).should eq Bytes[
        0x3f, 0xe1, 0x07,
      ]
    end

    it "resizes and evicts immediately without restoring entries on increase" do
      encoder = HPack::Encoder.new(max_table_size: 128)
      fields = [
        HPack::HeaderField.new(
          "x-old",
          "a" * 20,
          indexing: HPack::Indexing::ALWAYS
        ),
        HPack::HeaderField.new(
          "x-new",
          "b" * 20,
          indexing: HPack::Indexing::ALWAYS
        ),
      ]
      seed_block = encoder.encode(fields)
      decoder = HPack::Decoder.new(128)
      decoder.decode(seed_block)

      encoder.table.size.should eq 2
      encoder.resize_table(60)
      encoder.table.to_a.should eq [{"x-new", "b" * 20}]
      encoder.table.maximum.should eq 60

      encoder.resize_table(128)
      encoder.table.to_a.should eq [{"x-new", "b" * 20}]
      encoder.table.maximum.should eq 128

      update = encoder.encode([] of Tuple(String, String))
      update.should eq Bytes[0x3f, 0x1d, 0x3f, 0x61]
      decoder.decode(update)
      decoder.table.to_a.should eq encoder.table.to_a
      decoder.table.maximum.should eq encoder.table.maximum
    end

    it "emits pending updates through every public encoding path" do
      headers = HTTP::Headers.new
      tuples = [] of Tuple(String, String)
      fields = [] of HPack::HeaderField
      decoded = [] of HPack::DecodedHeader

      EncoderTableSizeSpec.resized_encoder.encode(headers).should eq Bytes[0x20]
      EncoderTableSizeSpec.resized_encoder.encode(headers) do |_name, _value|
        nil
      end.should eq Bytes[0x20]
      EncoderTableSizeSpec.resized_encoder.encode(tuples).should eq Bytes[0x20]
      EncoderTableSizeSpec.resized_encoder.encode(tuples) do |_name, _value|
        nil
      end.should eq Bytes[0x20]
      EncoderTableSizeSpec.resized_encoder.encode(fields).should eq Bytes[0x20]
      EncoderTableSizeSpec.resized_encoder.encode(fields) do |_name, _value|
        nil
      end.should eq Bytes[0x20]
      EncoderTableSizeSpec.resized_encoder.encode(decoded).should eq Bytes[0x20]

      output = IO::Memory.new
      EncoderTableSizeSpec.resized_encoder.encode_into(headers, output)
      output.to_slice.should eq Bytes[0x20]

      output.clear
      EncoderTableSizeSpec.resized_encoder.encode_into(headers, output) do |_name, _value|
        nil
      end
      output.to_slice.should eq Bytes[0x20]

      output.clear
      EncoderTableSizeSpec.resized_encoder.encode_into(tuples, output)
      output.to_slice.should eq Bytes[0x20]

      output.clear
      EncoderTableSizeSpec.resized_encoder.encode_into(tuples, output) do |_name, _value|
        nil
      end
      output.to_slice.should eq Bytes[0x20]

      output.clear
      EncoderTableSizeSpec.resized_encoder.encode_into(fields, output)
      output.to_slice.should eq Bytes[0x20]

      output.clear
      EncoderTableSizeSpec.resized_encoder.encode_into(fields, output) do |_name, _value|
        nil
      end
      output.to_slice.should eq Bytes[0x20]

      output.clear
      EncoderTableSizeSpec.resized_encoder.encode_into(decoded, output)
      output.to_slice.should eq Bytes[0x20]
    end

    it "prefixes headers and runs policy callbacks after the update" do
      encoder = HPack::Encoder.new
      output = IO::Memory.new
      saw_update = false
      encoder.resize_table(0)

      encoder.encode_into([{"x", "y"}], output) do |_name, _value|
        saw_update = output.to_slice == Bytes[0x20]
        nil
      end

      saw_update.should be_true
      output.to_slice.should eq Bytes[
        0x20,
        0x00, 0x01, 0x78, 0x01, 0x79,
      ]
    end

    it "keeps encoder and decoder table state synchronized with new entries" do
      encoder = HPack::Encoder.new(max_table_size: 128)
      decoder = HPack::Decoder.new(128)
      encoder.resize_table(63)
      decoder.max_table_size = 63
      fields = [
        HPack::HeaderField.new(
          "x",
          "y",
          indexing: HPack::Indexing::ALWAYS
        ),
      ]

      encoded = encoder.encode(fields)

      encoded.should eq Bytes[
        0x3f, 0x20,
        0x40, 0x01, 0x78, 0x01, 0x79,
      ]
      decoder.decode(encoded).should eq HTTP::Headers{"x" => "y"}
      decoder.table.to_a.should eq encoder.table.to_a
      decoder.table.maximum.should eq encoder.table.maximum
    end

    it "uses the compatibility writer path and preserves existing output" do
      encoder = HPack::Encoder.new
      output = IO::Memory.new
      output.write_byte(0xaa)
      encoder.resize_table(0)

      bytes = encoder.encode(HTTP::Headers.new, _writer: output)

      bytes.should eq Bytes[0xaa, 0x20]
    end

    it "consumes pending updates after one successful block" do
      encoder = HPack::Encoder.new
      encoder.resize_table(0)

      encoder.encode([] of Tuple(String, String)).should eq Bytes[0x20]
      encoder.encode([] of Tuple(String, String)).should be_empty
    end

    it "retains pending state when a callback fails and rolls back insertions" do
      encoder = HPack::Encoder.new(max_table_size: 128)
      encoder.encode([
        HPack::HeaderField.new(
          "x-seed",
          "a" * 20,
          indexing: HPack::Indexing::ALWAYS
        ),
      ])
      encoder.resize_table(64)
      expected_table = encoder.table.to_a
      expected_bytesize = encoder.table.bytesize
      fields = [
        HPack::HeaderField.new(
          "x-added",
          "b" * 20,
          indexing: HPack::Indexing::ALWAYS
        ),
        HPack::HeaderField.new("x-failure", "value"),
      ]

      expect_raises(Exception, "forced policy failure") do
        encoder.encode(fields) do |name, _value|
          raise "forced policy failure" if name == "x-failure"
          nil
        end
      end

      encoder.table.to_a.should eq expected_table
      encoder.table.bytesize.should eq expected_bytesize
      encoder.table.maximum.should eq 64
      encoder.encode([] of Tuple(String, String)).should eq Bytes[0x3f, 0x21]
    end

    it "retains the complete update after a writer fails during its prefix" do
      encoder = HPack::Encoder.new
      writer = EncoderTableSizeSpec::FailingWriter.new(1)
      encoder.resize_table(63)

      expect_raises(IO::Error, "forced writer failure") do
        encoder.encode_into([] of Tuple(String, String), writer)
      end

      writer.output.to_slice.should eq Bytes[0x3f]
      encoder.encode([] of Tuple(String, String)).should eq Bytes[0x3f, 0x20]
    end

    it "retains pending state and rolls back insertion after a writer failure" do
      encoder = HPack::Encoder.new(max_table_size: 128)
      writer = EncoderTableSizeSpec::FailingWriter.new(3)
      encoder.resize_table(63)

      expect_raises(IO::Error, "forced writer failure") do
        encoder.encode_into(
          [
            HPack::HeaderField.new(
              "x-added",
              "value",
              indexing: HPack::Indexing::ALWAYS
            ),
          ],
          writer
        )
      end

      writer.output.to_slice.should eq Bytes[0x3f, 0x20, 0x40]
      encoder.table.should be_empty
      encoder.table.bytesize.should eq 0
      encoder.table.maximum.should eq 63
      encoder.encode([] of Tuple(String, String)).should eq Bytes[0x3f, 0x20]
    end

    {% if flag?(:preview_mt) %}
      it "serializes resize operations with field-block encoding" do
        encoder = HPack::Encoder.new
        writer_started = Channel(Nil).new
        writer_release = Channel(Nil).new
        encode_done = Channel(Exception?).new
        resize_started = Channel(Nil).new
        resize_done = Channel(Exception?).new
        writer = EncoderTableSizeSpec::BarrierWriter.new(
          writer_started,
          writer_release
        )

        spawn do
          begin
            encoder.encode_into([{"x", "y"}], writer)
            encode_done.send(nil)
          rescue error
            encode_done.send(error)
          end
        end
        writer_started.receive

        spawn do
          begin
            resize_started.send(nil)
            encoder.resize_table(0)
            resize_done.send(nil)
          rescue error
            resize_done.send(error)
          end
        end
        resize_started.receive
        Fiber.yield

        resize_completed_early = false
        select
        when error = resize_done.receive
          raise error if error
          resize_completed_early = true
        when timeout(25.milliseconds)
        end

        writer_release.send(nil)
        if error = encode_done.receive
          raise error
        end
        unless resize_completed_early
          if error = resize_done.receive
            raise error
          end
        end

        resize_completed_early.should be_false
        writer.output.to_slice.should eq Bytes[
          0x00, 0x01, 0x78, 0x01, 0x79,
        ]
        encoder.encode([] of Tuple(String, String)).should eq Bytes[0x20]
      end
    {% end %}
  end
end
