require "./spec_helper"

module FieldPolicySpec
  class FailingWriter < IO
    getter output = IO::Memory.new

    def read(slice : Bytes) : Int32
      0
    end

    def write(slice : Bytes) : Nil
      output.write(slice)
      raise IO::Error.new("forced writer failure")
    end
  end
end

describe "per-field encoding policies" do
  it "mixes indexing and Huffman policies with exact wire output" do
    fields = [
      HPack::HeaderField.new(
        ":method",
        "GET",
        indexing: HPack::Indexing::INDEXED,
        huffman: HPack::HuffmanMode::NEVER
      ),
      HPack::HeaderField.new(
        "x-stable",
        "alpha",
        indexing: HPack::Indexing::ALWAYS,
        huffman: HPack::HuffmanMode::NEVER
      ),
      HPack::HeaderField.new(
        "x-stable",
        "beta",
        indexing: HPack::Indexing::NONE,
        huffman: HPack::HuffmanMode::ALWAYS
      ),
      HPack::HeaderField.new(
        "authorization",
        "secret",
        indexing: HPack::Indexing::NEVER,
        huffman: HPack::HuffmanMode::NEVER
      ),
    ]
    encoder = HPack::Encoder.new

    encoder.encode(fields).should eq Bytes[
      0x82,
      0x40, 0x08, 0x78, 0x2d, 0x73, 0x74, 0x61, 0x62, 0x6c, 0x65,
      0x05, 0x61, 0x6c, 0x70, 0x68, 0x61,
      0x0f, 0x2f, 0x83, 0x8c, 0xa9, 0x1f,
      0x1f, 0x08, 0x06, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74,
    ]
    encoder.table.to_a.should eq [{"x-stable", "alpha"}]
  end

  it "uses Huffman SMALLER only for strings that shrink" do
    fields = [
      HPack::HeaderField.new(
        "cache-control",
        "www.example.com",
        huffman: HPack::HuffmanMode::SMALLER
      ),
      HPack::HeaderField.new(
        "cache-control",
        "new",
        huffman: HPack::HuffmanMode::SMALLER
      ),
      HPack::HeaderField.new(
        "cache-control",
        "!",
        huffman: HPack::HuffmanMode::SMALLER
      ),
    ]

    HPack::Encoder.new.encode(fields).should eq Bytes[
      0x0f, 0x09, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b,
      0xa0, 0xab, 0x90, 0xf4, 0xff,
      0x0f, 0x09, 0x03, 0x6e, 0x65, 0x77,
      0x0f, 0x09, 0x01, 0x21,
    ]
  end

  it "chooses adaptive Huffman representations independently for names and values" do
    fields = [
      HPack::HeaderField.new(
        "custom-key",
        "!",
        huffman: HPack::HuffmanMode::SMALLER
      ),
      HPack::HeaderField.new(
        "!",
        "www.example.com",
        huffman: HPack::HuffmanMode::SMALLER
      ),
    ]

    HPack::Encoder.new.encode(fields).should eq Bytes[
      0x00, 0x88, 0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f,
      0x01, 0x21,
      0x00, 0x01, 0x21, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a,
      0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff,
    ]
  end

  it "preserves duplicate order while applying different field policies" do
    fields = [
      HPack::HeaderField.new("x-dupe", "one", indexing: HPack::Indexing::ALWAYS),
      HPack::HeaderField.new("x-dupe", "two", indexing: HPack::Indexing::NEVER),
      HPack::HeaderField.new("x-dupe", "three", indexing: HPack::Indexing::NONE),
    ]
    encoder = HPack::Encoder.new
    encoded = encoder.encode(fields)
    decoded = HPack::Decoder.new.decode_with_metadata(encoded)

    decoded[:fields].map { |field| {field.name, field.value} }.should eq [
      {"x-dupe", "one"},
      {"x-dupe", "two"},
      {"x-dupe", "three"},
    ]
    decoded[:fields].map(&.indexing).should eq [
      HPack::Indexing::ALWAYS,
      HPack::Indexing::NEVER,
      HPack::Indexing::NONE,
    ]
    encoder.table.to_a.should eq [{"x-dupe", "one"}]
  end

  it "resolves explicit options before callback and per-call options" do
    fields = [
      HPack::HeaderField.new(
        "X-Explicit",
        "www.example.com",
        indexing: HPack::Indexing::NEVER,
        huffman: HPack::HuffmanMode::ALWAYS
      ),
      HPack::HeaderField.new("X-Callback", "callback"),
      HPack::HeaderField.new("X-Call", "call"),
    ]
    observed = [] of Tuple(String, String)
    encoder = HPack::Encoder.new(HPack::Indexing::INDEXED, true)

    actual = encoder.encode(
      fields,
      HPack::Indexing::NONE,
      HPack::HuffmanMode::NEVER
    ) do |name, value|
      observed << {name, value}
      if name == "x-callback"
        HPack::FieldOptions.new(
          indexing: HPack::Indexing::ALWAYS,
          huffman: HPack::HuffmanMode::ALWAYS
        )
      elsif name == "x-explicit"
        HPack::FieldOptions.new(
          indexing: HPack::Indexing::ALWAYS,
          huffman: HPack::HuffmanMode::NEVER
        )
      else
        HPack::FieldOptions.new(huffman: HPack::HuffmanMode::NEVER)
      end
    end

    expected_writer = IO::Memory.new
    reference = HPack::Encoder.new
    reference.encode_into(
      [{"x-explicit", "www.example.com"}],
      expected_writer,
      HPack::Indexing::NEVER,
      true
    )
    reference.encode_into(
      [{"x-callback", "callback"}],
      expected_writer,
      HPack::Indexing::ALWAYS,
      true
    )
    reference.encode_into(
      [{"x-call", "call"}],
      expected_writer,
      HPack::Indexing::NONE,
      false
    )

    actual.should eq expected_writer.to_slice
    observed.should eq [
      {"x-explicit", "www.example.com"},
      {"x-callback", "callback"},
      {"x-call", "call"},
    ]
    encoder.table.to_a.should eq [{"x-callback", "callback"}]
  end

  it "uses instance defaults when no later policy axis supplies a value" do
    fields = [HPack::HeaderField.new("x-default", "value")]

    actual = HPack::Encoder.new(
      HPack::Indexing::ALWAYS,
      true
    ).encode(fields) { |_name, _value| nil }
    expected = HPack::Encoder.new.encode(
      [{"x-default", "value"}],
      HPack::Indexing::ALWAYS,
      true
    )

    actual.should eq expected
  end

  it "evaluates HTTP policies once after normalization in final wire order" do
    headers = HTTP::Headers.new
    headers.add("X-Regular", "one")
    headers.add(":PATH", "/first")
    headers.add("X-Regular", "two")
    headers.add(":METHOD", "GET")
    observed = [] of Tuple(String, String)

    actual = HPack::Encoder.new.encode(
      headers,
      HPack::Indexing::NONE,
      HPack::HuffmanMode::NEVER
    ) do |name, value|
      observed << {name, value}
      nil
    end

    observed.should eq [
      {":path", "/first"},
      {":method", "GET"},
      {"x-regular", "one"},
      {"x-regular", "two"},
    ]
    actual.should eq HPack::Encoder.new.encode(headers)
  end

  it "maps legacy Boolean Huffman arguments byte-for-byte" do
    headers = HTTP::Headers{
      ":path"      => "/sample/path",
      "custom-key" => "custom-value",
    }
    fields = [
      {":path", "/sample/path"},
      {"custom-key", "custom-value"},
    ]

    [false, true].each do |legacy|
      mode = legacy ? HPack::HuffmanMode::ALWAYS : HPack::HuffmanMode::NEVER
      expected = HPack::Encoder.new.encode(headers, HPack::Indexing::NONE, legacy)

      HPack::Encoder.new.encode(
        headers,
        HPack::Indexing::NONE,
        mode
      ) { |_name, _value| nil }.should eq expected
      HPack::Encoder.new.encode(
        fields,
        HPack::Indexing::NONE,
        mode
      ) { |_name, _value| nil }.should eq expected
      HPack::Encoder.new.encode(
        fields.map { |name, value| HPack::HeaderField.new(name, value) },
        HPack::Indexing::NONE,
        legacy
      ).should eq expected
    end
  end

  it "uses INDEXED for exact matches and NONE for literal fallbacks" do
    fields = [
      HPack::HeaderField.new(
        "x-dynamic",
        "value",
        indexing: HPack::Indexing::ALWAYS
      ),
      HPack::HeaderField.new(
        "x-dynamic",
        "value",
        indexing: HPack::Indexing::INDEXED
      ),
      HPack::HeaderField.new(
        ":method",
        "GET",
        indexing: HPack::Indexing::INDEXED
      ),
      HPack::HeaderField.new(
        "x-missing",
        "value",
        indexing: HPack::Indexing::INDEXED
      ),
    ]
    encoder = HPack::Encoder.new
    encoded = encoder.encode(fields)
    decoded = HPack::Decoder.new.decode_with_metadata(encoded)

    encoded.includes?(0xbe_u8).should be_true
    encoded.includes?(0x82_u8).should be_true
    decoded[:fields].map(&.indexing).should eq [
      HPack::Indexing::ALWAYS,
      HPack::Indexing::INDEXED,
      HPack::Indexing::INDEXED,
      HPack::Indexing::NONE,
    ]
    encoder.table.to_a.should eq [{"x-dynamic", "value"}]
  end

  it "forwards decoded NEVER metadata through owned and caller-owned output" do
    encoded = Bytes[
      0x82,
      0x1f, 0x08, 0x06, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74,
    ]
    decoded = HPack::Decoder.new.decode_with_metadata(encoded)

    owned = HPack::Encoder.new.encode(
      decoded[:fields],
      huffman: HPack::HuffmanMode::NEVER
    )
    writer = IO::Memory.new
    writer.write_byte(0xaa)
    HPack::Encoder.new.encode_into(decoded[:fields], writer, huffman: false)

    owned.should eq encoded
    writer.to_slice.should eq Bytes[0xaa] + encoded
    forwarded = HPack::Decoder.new.decode_with_metadata(owned)
    forwarded[:headers].should eq decoded[:headers]
    forwarded[:fields].should eq decoded[:fields]
  end

  it "returns equivalent owned and caller-owned policy output" do
    fields = [
      HPack::HeaderField.new("x-one", "www.example.com"),
      HPack::HeaderField.new("x-two", "!"),
    ]
    owned_calls = 0
    owned = HPack::Encoder.new.encode(
      fields,
      HPack::Indexing::NONE,
      HPack::HuffmanMode::NEVER
    ) do |_name, _value|
      owned_calls += 1
      HPack::FieldOptions.new(huffman: HPack::HuffmanMode::SMALLER)
    end

    writer_calls = 0
    writer = IO::Memory.new
    HPack::Encoder.new.encode_into(
      fields,
      writer,
      HPack::Indexing::NONE,
      HPack::HuffmanMode::NEVER
    ) do |_name, _value|
      writer_calls += 1
      HPack::FieldOptions.new(huffman: HPack::HuffmanMode::SMALLER)
    end

    writer.to_slice.should eq owned
    owned_calls.should eq fields.size
    writer_calls.should eq fields.size
  end

  it "rejects combined indexing flags on policy inputs" do
    invalid = HPack::Indexing::ALWAYS | HPack::Indexing::NEVER

    expect_raises(ArgumentError, /invalid indexing/) do
      HPack::Encoder.new.encode(
        [HPack::HeaderField.new("x", "value", indexing: invalid)]
      )
    end
    expect_raises(ArgumentError, /invalid indexing/) do
      HPack::Encoder.new.encode(
        [{"x", "value"}],
        invalid,
        HPack::HuffmanMode::NEVER
      ) { |_name, _value| nil }
    end
    expect_raises(ArgumentError, /invalid indexing/) do
      HPack::Encoder.new.encode(HTTP::Headers{"x" => "value"}) do |_name, _value|
        HPack::FieldOptions.new(indexing: invalid)
      end
    end
  end

  it "rolls back an owned call when its policy raises after insertion" do
    encoder = HPack::Encoder.new
    fields = [
      HPack::HeaderField.new(
        "x-inserted",
        "one",
        indexing: HPack::Indexing::ALWAYS
      ),
      HPack::HeaderField.new("x-failure", "two"),
    ]

    expect_raises(Exception, "forced policy failure") do
      encoder.encode(fields) do |name, _value|
        raise "forced policy failure" if name == "x-failure"
        nil
      end
    end

    encoder.table.should be_empty
    encoder.table.bytesize.should eq 0

    encoded = encoder.encode([{"x-inserted", "one"}])
    decoder = HPack::Decoder.new
    decoded = decoder.decode_with_metadata(encoded)
    decoded[:headers].should eq HTTP::Headers{"x-inserted" => "one"}
    decoded[:fields].map(&.indexing).should eq [HPack::Indexing::NONE]
    encoder.table.to_a.should eq decoder.table.to_a
  end

  it "rolls back table order and size when an external writer raises" do
    encoder = HPack::Encoder.new
    seed = [
      HPack::HeaderField.new(
        "x-seed-old",
        "one",
        indexing: HPack::Indexing::ALWAYS
      ),
      HPack::HeaderField.new(
        "x-seed-new",
        "two",
        indexing: HPack::Indexing::ALWAYS
      ),
    ]
    seed_block = encoder.encode(seed)
    decoder = HPack::Decoder.new
    decoder.decode(seed_block)
    expected_table = encoder.table.to_a
    expected_bytesize = encoder.table.bytesize
    writer = FieldPolicySpec::FailingWriter.new

    expect_raises(IO::Error, "forced writer failure") do
      encoder.encode_into(
        [
          HPack::HeaderField.new(
            "x-lost",
            "value",
            indexing: HPack::Indexing::ALWAYS
          ),
        ],
        writer
      )
    end

    # `writer#write` is called exactly once, with the complete encoded
    # block, before it raises: a delivery failure never exposes a partial
    # block, only the whole thing or nothing.
    round_trip = HPack::Decoder.new
    round_trip.decode(writer.output.to_slice).should eq HTTP::Headers{"x-lost" => "value"}
    encoder.table.to_a.should eq expected_table
    encoder.table.bytesize.should eq expected_bytesize

    followup = encoder.encode([{"x-seed-old", "one"}])
    decoder.decode(followup).should eq HTTP::Headers{"x-seed-old" => "one"}
    encoder.table.to_a.should eq decoder.table.to_a
    encoder.table.bytesize.should eq decoder.table.bytesize
  end
end
