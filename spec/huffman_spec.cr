require "./spec_helper"

module HuffmanSpec
  EOS_CODE = (1_u32 << 30) - 1

  class InvalidEncoding < Exception
  end

  extend self

  def reference_encode(input : String) : Bytes
    bit_length = input.each_byte.sum(0_i64) do |byte|
      HPack::Huffman::CODES[byte][2]
    end
    output = Bytes.new(((bit_length + 7) // 8).to_i32, 0_u8)
    offset = 0_i64

    input.each_byte do |byte|
      _, code, length = HPack::Huffman::CODES[byte]

      (length - 1).downto(0) do |bit|
        byte_index = offset // 8
        bit_index = offset % 8
        output[byte_index] |= 0x80_u8 >> bit_index if code.bit(bit) == 1
        offset += 1
      end
    end

    unless bit_length % 8 == 0
      output[output.size - 1] |= 0xff_u8 >> (bit_length % 8)
    end
    output
  end

  def reference_decode(input : Bytes) : String
    output = IO::Memory.new
    prefix = 0_u32
    prefix_length = 0

    input.each do |byte|
      7.downto(0) do |bit|
        prefix = (prefix << 1) | byte.bit(bit).to_u32
        prefix_length += 1

        if prefix_length == 30 && prefix == EOS_CODE
          raise InvalidEncoding.new("EOS is not data")
        end

        if value = exact_symbol(prefix, prefix_length)
          output.write_byte(value)
          prefix = 0_u32
          prefix_length = 0
        elsif !valid_prefix?(prefix, prefix_length)
          raise InvalidEncoding.new("invalid code")
        end
      end
    end

    unless prefix_length == 0
      if prefix_length > 7 || prefix != EOS_CODE >> (30 - prefix_length)
        raise InvalidEncoding.new("invalid padding")
      end
    end

    output.to_s
  end

  def code_bits(input : String) : Array(UInt8)
    bits = [] of UInt8

    input.each_byte do |byte|
      _, code, length = HPack::Huffman::CODES[byte]
      (length - 1).downto(0) { |bit| bits << code.bit(bit).to_u8 }
    end

    bits
  end

  def pack_bits(bits : Array(UInt8)) : Bytes
    raise ArgumentError.new("bit count must be byte-aligned") unless bits.size % 8 == 0

    Bytes.new(bits.size // 8) do |byte_index|
      value = 0_u8
      8.times do |bit_index|
        value = (value << 1) | bits[byte_index * 8 + bit_index]
      end
      value
    end
  end

  def assert_matches_reference(input : Bytes)
    expected = reference_decode(input)
    HPack.huffman.decode(input).should eq expected
  rescue InvalidEncoding
    accepted = true
    begin
      HPack.huffman.decode(input)
    rescue HPack::Error
      accepted = false
    end
    accepted.should be_false, "accepted invalid Huffman bytes #{input.hexstring}"
  end

  private def exact_symbol(prefix : UInt32, prefix_length : Int32) : UInt8?
    HPack::Huffman::CODES.each do |value, code, length|
      return value if length == prefix_length && code == prefix
    end
    nil
  end

  private def valid_prefix?(prefix : UInt32, prefix_length : Int32) : Bool
    return true if prefix_length < 30 && EOS_CODE >> (30 - prefix_length) == prefix

    HPack::Huffman::CODES.any? do |_value, code, length|
      length > prefix_length && code >> (length - prefix_length) == prefix
    end
  end
end

describe HPack::Huffman do
  describe "#encoded_bit_length" do
    it "reports encoded bit and byte lengths without encoding" do
      HPack.huffman.encoded_bit_length("").should eq 0_u64
      HPack.huffman.encoded_size("").should eq 0
      HPack.huffman.encoded_bit_length("!").should eq 10_u64
      HPack.huffman.encoded_size("!").should eq 2
      HPack.huffman.encoded_size("www.example.com").should eq 12
    end
  end

  describe "#encode" do
    it "encodes empty input" do
      HPack.huffman.encode("").should be_empty
    end

    it "matches RFC 7541 vectors" do
      vectors = {
        {"www.example.com", Bytes[0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff]},
        {"no-cache", Bytes[0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf]},
        {"custom-key", Bytes[0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f]},
        {"custom-value", Bytes[0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf]},
      }

      vectors.each do |input, expected|
        HPack.huffman.encode(input).should eq expected
      end
    end

    it "encodes a symbol whose code spans multiple bytes" do
      HPack.huffman.encode("!").should eq Bytes[0xfe_u8, 0x3f_u8]
    end

    it "allocates enough output for expanding symbols" do
      encoded = HPack.huffman.encode(String.new(Bytes[0_u8, 10_u8]))

      encoded.size.should eq 6
      HPack.huffman.decode(encoded).to_slice.should eq Bytes[0_u8, 10_u8]
    end

    it "encodes directly into a caller-owned destination given a bit length" do
      input = "www.example.com"
      bit_length = HPack.huffman.encoded_bit_length(input)
      expected = HPack.huffman.encode(input)

      exact = Bytes.new(expected.size)
      written = HPack.huffman.encode(input, exact, bit_length)
      written.should eq expected.size
      exact.should eq expected

      # An oversized destination is written identically in its leading
      # bytes; only the first `written` bytes are meaningful to the caller.
      oversized = Bytes.new(expected.size + 16)
      written_oversized = HPack.huffman.encode(input, oversized, bit_length)
      written_oversized.should eq expected.size
      oversized[0, expected.size].should eq expected
    end

    it "raises when the destination is too small for the encoded output" do
      input = "www.example.com"
      bit_length = HPack.huffman.encoded_bit_length(input)
      too_small = Bytes.new(1)

      expect_raises(HPack::Error) do
        HPack.huffman.encode(input, too_small, bit_length)
      end
    end

    it "matches a bit-at-a-time reference for every symbol at every bit offset" do
      256.times do |value|
        8.times do |prefix_symbols|
          input = ("0" * prefix_symbols) + String.new(Bytes[value.to_u8])

          HPack.huffman.encode(input).should eq HuffmanSpec.reference_encode(input)
        end
      end
    end

    it "round trips every possible input byte individually and together" do
      all_bytes = String.new(Bytes.new(256, &.to_u8))

      256.times do |value|
        input = String.new(Bytes[value.to_u8])

        HPack.huffman.decode(HPack.huffman.encode(input)).to_slice.should eq input.to_slice
      end
      HPack.huffman.decode(HPack.huffman.encode(all_bytes)).to_slice.should eq all_bytes.to_slice
    end
  end

  describe "#decode" do
    it "decodes empty input" do
      HPack.huffman.decode(Bytes.empty).should be_empty
    end

    it "decodes RFC 7541 vectors" do
      HPack.huffman.decode(Bytes[0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff])
        .should eq "www.example.com"
      HPack.huffman.decode(Bytes[0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf]).should eq "no-cache"
      HPack.huffman.decode(Bytes[0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f]).should eq "custom-key"
      HPack.huffman.decode(Bytes[0x25, 0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf]).should eq "custom-value"
    end

    it "writes decoded bytes to a caller-owned buffer" do
      output = IO::Memory.new
      output << "prefix:"

      HPack.huffman.decode(Bytes[0xfe_u8, 0x3f_u8], output)

      output.to_s.should eq "prefix:!"
    end

    it "decodes a symbol that does not finish in the first byte" do
      HPack.huffman.decode(Bytes[0xfe_u8, 0x3f_u8]).should eq "!"
    end

    it "matches a reference decoder for every one-byte input" do
      256.times do |value|
        HuffmanSpec.assert_matches_reference(Bytes[value.to_u8])
      end
    end

    it "handles every terminal suffix bit pattern" do
      1.upto(7) do |suffix_length|
        prefix_symbols = (0..7).find! do |count|
          (count * 5 + suffix_length) % 8 == 0
        end
        prefix_bits = HuffmanSpec.code_bits("0" * prefix_symbols)

        (1 << suffix_length).times do |suffix|
          bits = prefix_bits.dup
          (suffix_length - 1).downto(0) do |bit|
            bits << suffix.bit(bit).to_u8
          end

          HuffmanSpec.assert_matches_reference(HuffmanSpec.pack_bits(bits))
        end
      end
    end

    it "rejects the EOS symbol at every bit alignment" do
      8.times do |prefix_symbols|
        bits = HuffmanSpec.code_bits("0" * prefix_symbols)
        30.times { bits << 1_u8 }
        while bits.size % 8 != 0
          bits << 1_u8
        end

        expect_raises(HPack::Error) do
          HPack.huffman.decode(HuffmanSpec.pack_bits(bits))
        end
      end
    end

    it "rejects padding longer than seven bits" do
      expect_raises(HPack::Error) do
        HPack.huffman.decode(Bytes[0xff_u8])
      end
    end

    it "rejects padding that is not an EOS prefix" do
      expect_raises(HPack::Error) do
        HPack.huffman.decode(Bytes[0x18_u8])
      end
    end

    it "rejects the EOS symbol" do
      expect_raises(HPack::Error) do
        HPack.huffman.decode(Bytes[0xff_u8, 0xff_u8, 0xff_u8, 0xff_u8])
      end
    end

    {% if flag?(:preview_mt) %}
      it "decodes concurrently without sharing output state" do
        all_bytes = String.new(Bytes.new(256, &.to_u8))
        fixtures = {
          {"!", HPack.huffman.encode("!")},
          {"www.example.com", HPack.huffman.encode("www.example.com")},
          {all_bytes, HPack.huffman.encode(all_bytes)},
        }
        worker_count = 16
        failures = Channel(Exception?).new(worker_count)

        worker_count.times do
          spawn do
            begin
              100.times do
                fixtures.each do |expected, encoded|
                  actual = HPack.huffman.decode(encoded)
                  raise "concurrent decode mismatch" unless actual == expected
                end
              end
              failures.send(nil)
            rescue error
              failures.send(error)
            end
          end
        end

        worker_count.times do
          if failure = failures.receive
            raise failure
          end
        end
      end
    {% end %}
  end
end
