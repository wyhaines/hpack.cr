require "./error"
require "./huffman/decode_table"

module HPack
  class Huffman
    private getter table : Slice({UInt8, UInt32, UInt8})
    private getter decode_table : Slice(DecodeTransition)

    def initialize(table)
      unless table.size == 256
        raise ArgumentError.new("Huffman table must contain 256 symbols")
      end

      @table = Slice({UInt8, UInt32, UInt8}).new(table.size, read_only: true) do |index|
        value, code, length = table[index]
        {value.to_u8, code.to_u32, length.to_u8}
      end
      @decode_table = build_decode_table
    end

    # Returns the number of bits needed to Huffman-encode *string*.
    def encoded_bit_length(string : String) : Int64
      bit_length = 0_i64

      string.each_byte do |byte|
        bit_length += table[byte][2]
      end

      bit_length
    end

    # Returns the byte size needed to Huffman-encode *string*.
    #
    # Raises `HPack::Error` if the encoded result cannot fit in a Crystal
    # `Bytes` value.
    def encoded_size(string : String) : Int32
      encoded_size(encoded_bit_length(string))
    end

    # Huffman-encodes *string* into *dest*, starting at offset 0.
    #
    # *bit_length* must equal `encoded_bit_length(string)` for this same
    # *string* — it is trusted as a sizing hint, not re-derived, so the
    # single sizing walk stays in the caller. That equality is verified as
    # writes happen, not merely assumed: every store into *dest* is bounds
    # checked against `dest.size` (raising `HPack::Error` rather than
    # corrupting memory through the unsafe pointer this method writes
    # through if *bit_length* understates the true length), and once the
    # string has been fully walked, the number of bytes actually written is
    # compared against the `(bit_length + 7) // 8` byte count the caller
    # implied; a mismatch (understated *or* overstated *bit_length*) raises
    # `HPack::Error` instead of silently returning a byte count that
    # includes stale, previously-written `dest` contents.
    #
    # On success, writes exactly `(bit_length + 7) // 8` bytes and returns
    # that count. *dest* must be at least that many bytes long; the caller
    # (the `Encoder`'s scratch buffer, in the common case) owns sizing it.
    def encode(string : String, dest : Bytes, bit_length : Int64) : Int32
      byte_count = encoded_size(bit_length)
      if dest.size < byte_count
        raise Error.new("destination buffer too small for huffman-encoded output")
      end

      out = dest.to_unsafe
      output_index = 0
      accumulator = 0_u64
      pending_bits = 0_u8

      string.each_byte do |byte|
        _, code, length = table[byte]
        accumulator = (accumulator << length) | code
        pending_bits += length

        while pending_bits >= 8
          pending_bits -= 8
          raise Error.new("huffman bit_length does not match string's actual encoded length") if output_index >= dest.size
          out[output_index] = (accumulator >> pending_bits).to_u8!
          output_index += 1
        end
      end

      if pending_bits > 0
        padding_bits = 8_u8 - pending_bits
        raise Error.new("huffman bit_length does not match string's actual encoded length") if output_index >= dest.size
        out[output_index] = ((accumulator << padding_bits) | (0xff_u64 >> pending_bits)).to_u8!
        output_index += 1
      end

      unless output_index == byte_count
        raise Error.new("huffman bit_length does not match string's actual encoded length")
      end

      byte_count
    end

    # Huffman-encodes *string* and returns a freshly allocated `Bytes`.
    def encode(string : String) : Bytes
      bit_length = encoded_bit_length(string)
      bytes = Bytes.new(encoded_size(bit_length))
      encode(string, bytes, bit_length)
      bytes
    end

    # Huffman-decodes *bytes* into *dest*, starting at offset 0, writing
    # through a raw pointer rather than a virtual `IO#write_byte` sink.
    #
    # Returns the number of bytes written. Returns `-1` if *dest* is too
    # small to hold the fully decoded output; callers that enforce a decoded
    # size cap (`Decoder#max_decoded_string_size`) treat that return value as
    # a size-violation rather than retrying with a larger buffer. Raises
    # `HPack::Error` on invalid Huffman padding or an encoded EOS symbol, same
    # as the `String`-returning overload below.
    def decode(bytes : Bytes, dest : Bytes) : Int32
      transition = DecodeTransition.new(0_u16, NO_VALUE, NO_VALUE, ACCEPTING)
      out = dest.to_unsafe
      cap = dest.size
      n = 0

      bytes.each do |byte|
        transition = decode_table[transition.next_state.to_i * 256 + byte]

        unless transition.first_value == NO_VALUE
          return -1 if n >= cap
          out[n] = transition.first_value.to_u8
          n += 1
        end

        unless transition.second_value == NO_VALUE
          return -1 if n >= cap
          out[n] = transition.second_value.to_u8
          n += 1
        end

        raise Error.new("node is nil!") if transition.invalid?
      end

      # RFC 7541, section 5.2
      unless transition.accepting?
        if transition.padding_too_long?
          raise Error.new("huffman string padding is larger than 7-bits")
        end

        raise Error.new("huffman string padding must use MSB of EOS symbol")
      end

      n
    end

    # Huffman-decodes *bytes* and returns a freshly allocated `String`.
    #
    # Allocates a local destination buffer sized to the maximum possible
    # decoded output (Huffman codes are at least 5 bits, so decoded output
    # never exceeds `bytes.size * 8 // 5 + 1` bytes); no shared or
    # fiber-cached scratch buffer is used.
    def decode(bytes : Bytes) : String
      dest = Bytes.new(bytes.size * 8 // 5 + 1)
      n = decode(bytes, dest)
      raise Error.new("huffman decode overflow") if n < 0 # cannot happen: dest is sized to the maximum possible output
      String.new(dest[0, n])
    end

    # Decodes *bytes* and writes the result to *output*.
    #
    # This method does not clear or rewind *output*. The caller owns and
    # controls the output buffer.
    #
    # A thin compatibility wrapper over the pointer-sink `#decode(bytes, dest)`
    # overload: it allocates a local destination sized to the maximum possible
    # decoded output (same bound as the `String`-returning overload above), so
    # the `-1` (undersized-destination) case can never occur here and is not
    # checked for.
    def decode(bytes : Bytes, output : IO) : Nil
      dest = Bytes.new(bytes.size * 8 // 5 + 1)
      n = decode(bytes, dest)
      output.write(dest[0, n])
    end

    # Returns the byte size needed to Huffman-encode a string whose encoded
    # bit length is *bit_length* (as returned by `#encoded_bit_length`).
    #
    # Raises `HPack::Error` if the encoded result cannot fit in a Crystal
    # `Bytes` value. Public so callers that already have a bit length in
    # hand (notably `Encoder#string`) can compute the byte size without
    # duplicating this arithmetic.
    def encoded_size(bit_length : Int64) : Int32
      byte_size = (bit_length + 7) // 8
      if byte_size > Int32::MAX
        raise Error.new("Huffman output exceeds maximum slice size")
      end
      byte_size.to_i32
    end

    # :nodoc:
    CODES = {
      {0_u8, 0b1111111111000, 13},
      {1_u8, 0b11111111111111111011000, 23},
      {2_u8, 0b1111111111111111111111100010, 28},
      {3_u8, 0b1111111111111111111111100011, 28},
      {4_u8, 0b1111111111111111111111100100, 28},
      {5_u8, 0b1111111111111111111111100101, 28},
      {6_u8, 0b1111111111111111111111100110, 28},
      {7_u8, 0b1111111111111111111111100111, 28},
      {8_u8, 0b1111111111111111111111101000, 28},
      {9_u8, 0b111111111111111111101010, 24},
      {10_u8, 0b111111111111111111111111111100, 30},
      {11_u8, 0b1111111111111111111111101001, 28},
      {12_u8, 0b1111111111111111111111101010, 28},
      {13_u8, 0b111111111111111111111111111101, 30},
      {14_u8, 0b1111111111111111111111101011, 28},
      {15_u8, 0b1111111111111111111111101100, 28},
      {16_u8, 0b1111111111111111111111101101, 28},
      {17_u8, 0b1111111111111111111111101110, 28},
      {18_u8, 0b1111111111111111111111101111, 28},
      {19_u8, 0b1111111111111111111111110000, 28},
      {20_u8, 0b1111111111111111111111110001, 28},
      {21_u8, 0b1111111111111111111111110010, 28},
      {22_u8, 0b111111111111111111111111111110, 30},
      {23_u8, 0b1111111111111111111111110011, 28},
      {24_u8, 0b1111111111111111111111110100, 28},
      {25_u8, 0b1111111111111111111111110101, 28},
      {26_u8, 0b1111111111111111111111110110, 28},
      {27_u8, 0b1111111111111111111111110111, 28},
      {28_u8, 0b1111111111111111111111111000, 28},
      {29_u8, 0b1111111111111111111111111001, 28},
      {30_u8, 0b1111111111111111111111111010, 28},
      {31_u8, 0b1111111111111111111111111011, 28},
      {32_u8, 0b010100, 6},
      {33_u8, 0b1111111000, 10},
      {34_u8, 0b1111111001, 10},
      {35_u8, 0b111111111010, 12},
      {36_u8, 0b1111111111001, 13},
      {37_u8, 0b010101, 6},
      {38_u8, 0b11111000, 8},
      {39_u8, 0b11111111010, 11},
      {40_u8, 0b1111111010, 10},
      {41_u8, 0b1111111011, 10},
      {42_u8, 0b11111001, 8},
      {43_u8, 0b11111111011, 11},
      {44_u8, 0b11111010, 8},
      {45_u8, 0b010110, 6},
      {46_u8, 0b010111, 6},
      {47_u8, 0b011000, 6},
      {48_u8, 0b00000, 5},
      {49_u8, 0b00001, 5},
      {50_u8, 0b00010, 5},
      {51_u8, 0b011001, 6},
      {52_u8, 0b011010, 6},
      {53_u8, 0b011011, 6},
      {54_u8, 0b011100, 6},
      {55_u8, 0b011101, 6},
      {56_u8, 0b011110, 6},
      {57_u8, 0b011111, 6},
      {58_u8, 0b1011100, 7},
      {59_u8, 0b11111011, 8},
      {60_u8, 0b111111111111100, 15},
      {61_u8, 0b100000, 6},
      {62_u8, 0b111111111011, 12},
      {63_u8, 0b1111111100, 10},
      {64_u8, 0b1111111111010, 13},
      {65_u8, 0b100001, 6},
      {66_u8, 0b1011101, 7},
      {67_u8, 0b1011110, 7},
      {68_u8, 0b1011111, 7},
      {69_u8, 0b1100000, 7},
      {70_u8, 0b1100001, 7},
      {71_u8, 0b1100010, 7},
      {72_u8, 0b1100011, 7},
      {73_u8, 0b1100100, 7},
      {74_u8, 0b1100101, 7},
      {75_u8, 0b1100110, 7},
      {76_u8, 0b1100111, 7},
      {77_u8, 0b1101000, 7},
      {78_u8, 0b1101001, 7},
      {79_u8, 0b1101010, 7},
      {80_u8, 0b1101011, 7},
      {81_u8, 0b1101100, 7},
      {82_u8, 0b1101101, 7},
      {83_u8, 0b1101110, 7},
      {84_u8, 0b1101111, 7},
      {85_u8, 0b1110000, 7},
      {86_u8, 0b1110001, 7},
      {87_u8, 0b1110010, 7},
      {88_u8, 0b11111100, 8},
      {89_u8, 0b1110011, 7},
      {90_u8, 0b11111101, 8},
      {91_u8, 0b1111111111011, 13},
      {92_u8, 0b1111111111111110000, 19},
      {93_u8, 0b1111111111100, 13},
      {94_u8, 0b11111111111100, 14},
      {95_u8, 0b100010, 6},
      {96_u8, 0b111111111111101, 15},
      {97_u8, 0b00011, 5},
      {98_u8, 0b100011, 6},
      {99_u8, 0b00100, 5},
      {100_u8, 0b100100, 6},
      {101_u8, 0b00101, 5},
      {102_u8, 0b100101, 6},
      {103_u8, 0b100110, 6},
      {104_u8, 0b100111, 6},
      {105_u8, 0b00110, 5},
      {106_u8, 0b1110100, 7},
      {107_u8, 0b1110101, 7},
      {108_u8, 0b101000, 6},
      {109_u8, 0b101001, 6},
      {110_u8, 0b101010, 6},
      {111_u8, 0b00111, 5},
      {112_u8, 0b101011, 6},
      {113_u8, 0b1110110, 7},
      {114_u8, 0b101100, 6},
      {115_u8, 0b01000, 5},
      {116_u8, 0b01001, 5},
      {117_u8, 0b101101, 6},
      {118_u8, 0b1110111, 7},
      {119_u8, 0b1111000, 7},
      {120_u8, 0b1111001, 7},
      {121_u8, 0b1111010, 7},
      {122_u8, 0b1111011, 7},
      {123_u8, 0b111111111111110, 15},
      {124_u8, 0b11111111100, 11},
      {125_u8, 0b11111111111101, 14},
      {126_u8, 0b1111111111101, 13},
      {127_u8, 0b1111111111111111111111111100, 28},
      {128_u8, 0b11111111111111100110, 20},
      {129_u8, 0b1111111111111111010010, 22},
      {130_u8, 0b11111111111111100111, 20},
      {131_u8, 0b11111111111111101000, 20},
      {132_u8, 0b1111111111111111010011, 22},
      {133_u8, 0b1111111111111111010100, 22},
      {134_u8, 0b1111111111111111010101, 22},
      {135_u8, 0b11111111111111111011001, 23},
      {136_u8, 0b1111111111111111010110, 22},
      {137_u8, 0b11111111111111111011010, 23},
      {138_u8, 0b11111111111111111011011, 23},
      {139_u8, 0b11111111111111111011100, 23},
      {140_u8, 0b11111111111111111011101, 23},
      {141_u8, 0b11111111111111111011110, 23},
      {142_u8, 0b111111111111111111101011, 24},
      {143_u8, 0b11111111111111111011111, 23},
      {144_u8, 0b111111111111111111101100, 24},
      {145_u8, 0b111111111111111111101101, 24},
      {146_u8, 0b1111111111111111010111, 22},
      {147_u8, 0b11111111111111111100000, 23},
      {148_u8, 0b111111111111111111101110, 24},
      {149_u8, 0b11111111111111111100001, 23},
      {150_u8, 0b11111111111111111100010, 23},
      {151_u8, 0b11111111111111111100011, 23},
      {152_u8, 0b11111111111111111100100, 23},
      {153_u8, 0b111111111111111011100, 21},
      {154_u8, 0b1111111111111111011000, 22},
      {155_u8, 0b11111111111111111100101, 23},
      {156_u8, 0b1111111111111111011001, 22},
      {157_u8, 0b11111111111111111100110, 23},
      {158_u8, 0b11111111111111111100111, 23},
      {159_u8, 0b111111111111111111101111, 24},
      {160_u8, 0b1111111111111111011010, 22},
      {161_u8, 0b111111111111111011101, 21},
      {162_u8, 0b11111111111111101001, 20},
      {163_u8, 0b1111111111111111011011, 22},
      {164_u8, 0b1111111111111111011100, 22},
      {165_u8, 0b11111111111111111101000, 23},
      {166_u8, 0b11111111111111111101001, 23},
      {167_u8, 0b111111111111111011110, 21},
      {168_u8, 0b11111111111111111101010, 23},
      {169_u8, 0b1111111111111111011101, 22},
      {170_u8, 0b1111111111111111011110, 22},
      {171_u8, 0b111111111111111111110000, 24},
      {172_u8, 0b111111111111111011111, 21},
      {173_u8, 0b1111111111111111011111, 22},
      {174_u8, 0b11111111111111111101011, 23},
      {175_u8, 0b11111111111111111101100, 23},
      {176_u8, 0b111111111111111100000, 21},
      {177_u8, 0b111111111111111100001, 21},
      {178_u8, 0b1111111111111111100000, 22},
      {179_u8, 0b111111111111111100010, 21},
      {180_u8, 0b11111111111111111101101, 23},
      {181_u8, 0b1111111111111111100001, 22},
      {182_u8, 0b11111111111111111101110, 23},
      {183_u8, 0b11111111111111111101111, 23},
      {184_u8, 0b11111111111111101010, 20},
      {185_u8, 0b1111111111111111100010, 22},
      {186_u8, 0b1111111111111111100011, 22},
      {187_u8, 0b1111111111111111100100, 22},
      {188_u8, 0b11111111111111111110000, 23},
      {189_u8, 0b1111111111111111100101, 22},
      {190_u8, 0b1111111111111111100110, 22},
      {191_u8, 0b11111111111111111110001, 23},
      {192_u8, 0b11111111111111111111100000, 26},
      {193_u8, 0b11111111111111111111100001, 26},
      {194_u8, 0b11111111111111101011, 20},
      {195_u8, 0b1111111111111110001, 19},
      {196_u8, 0b1111111111111111100111, 22},
      {197_u8, 0b11111111111111111110010, 23},
      {198_u8, 0b1111111111111111101000, 22},
      {199_u8, 0b1111111111111111111101100, 25},
      {200_u8, 0b11111111111111111111100010, 26},
      {201_u8, 0b11111111111111111111100011, 26},
      {202_u8, 0b11111111111111111111100100, 26},
      {203_u8, 0b111111111111111111111011110, 27},
      {204_u8, 0b111111111111111111111011111, 27},
      {205_u8, 0b11111111111111111111100101, 26},
      {206_u8, 0b111111111111111111110001, 24},
      {207_u8, 0b1111111111111111111101101, 25},
      {208_u8, 0b1111111111111110010, 19},
      {209_u8, 0b111111111111111100011, 21},
      {210_u8, 0b11111111111111111111100110, 26},
      {211_u8, 0b111111111111111111111100000, 27},
      {212_u8, 0b111111111111111111111100001, 27},
      {213_u8, 0b11111111111111111111100111, 26},
      {214_u8, 0b111111111111111111111100010, 27},
      {215_u8, 0b111111111111111111110010, 24},
      {216_u8, 0b111111111111111100100, 21},
      {217_u8, 0b111111111111111100101, 21},
      {218_u8, 0b11111111111111111111101000, 26},
      {219_u8, 0b11111111111111111111101001, 26},
      {220_u8, 0b1111111111111111111111111101, 28},
      {221_u8, 0b111111111111111111111100011, 27},
      {222_u8, 0b111111111111111111111100100, 27},
      {223_u8, 0b111111111111111111111100101, 27},
      {224_u8, 0b11111111111111101100, 20},
      {225_u8, 0b111111111111111111110011, 24},
      {226_u8, 0b11111111111111101101, 20},
      {227_u8, 0b111111111111111100110, 21},
      {228_u8, 0b1111111111111111101001, 22},
      {229_u8, 0b111111111111111100111, 21},
      {230_u8, 0b111111111111111101000, 21},
      {231_u8, 0b11111111111111111110011, 23},
      {232_u8, 0b1111111111111111101010, 22},
      {233_u8, 0b1111111111111111101011, 22},
      {234_u8, 0b1111111111111111111101110, 25},
      {235_u8, 0b1111111111111111111101111, 25},
      {236_u8, 0b111111111111111111110100, 24},
      {237_u8, 0b111111111111111111110101, 24},
      {238_u8, 0b11111111111111111111101010, 26},
      {239_u8, 0b11111111111111111110100, 23},
      {240_u8, 0b11111111111111111111101011, 26},
      {241_u8, 0b111111111111111111111100110, 27},
      {242_u8, 0b11111111111111111111101100, 26},
      {243_u8, 0b11111111111111111111101101, 26},
      {244_u8, 0b111111111111111111111100111, 27},
      {245_u8, 0b111111111111111111111101000, 27},
      {246_u8, 0b111111111111111111111101001, 27},
      {247_u8, 0b111111111111111111111101010, 27},
      {248_u8, 0b111111111111111111111101011, 27},
      {249_u8, 0b1111111111111111111111111110, 28},
      {250_u8, 0b111111111111111111111101100, 27},
      {251_u8, 0b111111111111111111111101101, 27},
      {252_u8, 0b111111111111111111111101110, 27},
      {253_u8, 0b111111111111111111111101111, 27},
      {254_u8, 0b111111111111111111111110000, 27},
      {255_u8, 0b11111111111111111111101110, 26},
      # {256_u8,  0b111111111111111111111111111111,  30}, # EOS symbol (invalid)
    }
  end

  def self.huffman
    HuffmanInstance
  end

  HuffmanInstance = Huffman.new(Huffman::CODES)
end
