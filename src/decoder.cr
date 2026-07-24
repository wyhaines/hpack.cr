require "./slice_reader"
require "./error"
require "./indexing"
require "./header_field"

module HPack
  # To decode headers, use a `HPack::Decoder` instance. By default, a decoder is created with a 4k (4096 bytes) table size. That table size can be changed in the constructor.
  #
  # ```
  # # To create a default Decoder:
  # decoder = HPack::Decoder.new
  #
  # # To create a decoder with a larger table size:
  # decoder = HPack::Decoder.new(8192)
  #
  # # To decode headers:
  # headers = decoder.decode(bytes)
  #
  # # To decode headers into an existing `HTTP::Headers` instance:
  # headers = decoder.decode(bytes, HTTP::Headers.new)
  # ```
  class Decoder
    private getter! reader : SliceReader
    getter table : DynamicTable
    getter max_table_size : Int32
    @required_table_size_update : Int32?

    def initialize(max_table_size = 4096)
      @max_table_size = normalize_table_size(max_table_size)
      @table = DynamicTable.new(@max_table_size)
      @huffman_output = IO::Memory.new
      @required_table_size_update = nil
    end

    # Changes the protocol limit for dynamic-table size updates.
    #
    # Reducing this limit below the peer's current table capacity requires a
    # conforming update at the beginning of the next decoded field block. The
    # table itself is resized only when that instruction is received.
    def max_table_size=(size : Int)
      normalized_size = normalize_table_size(size)
      if normalized_size < table.maximum
        @required_table_size_update =
          if required_size = @required_table_size_update
            normalized_size < required_size ? normalized_size : required_size
          else
            normalized_size
          end
      end
      @max_table_size = normalized_size
    end

    def decode(bytes, headers = HTTP::Headers.new)
      decode_into(bytes, headers, nil)
    end

    # Decodes headers and retains their ordered indexing representations.
    #
    # The returned `headers` value is the same value returned by `#decode`.
    # `fields` retains one entry per decoded field, including `Indexing::NEVER`
    # markers that intermediaries need when forwarding fields.
    def decode_with_metadata(bytes, headers = HTTP::Headers.new)
      fields = [] of DecodedHeader
      decode_into(bytes, headers, fields)
      {headers: headers, fields: fields}
    end

    private def decode_into(bytes, headers, fields : Array(DecodedHeader)?)
      @reader = SliceReader.new(bytes)
      decoded_header = false
      table_size_update_count = 0
      ensure_required_table_size_update

      until reader.done?
        if reader.current_byte.bit(7) == 1 # 1.......  indexed
          _index, name, value = literal_indexed
          indexing = Indexing::INDEXED
        elsif reader.current_byte.bit(6) == 1 # 01......  literal with incremental indexing
          _index, name, value = literal_with_incremental_indexing
          indexing = Indexing::ALWAYS
        elsif reader.current_byte.bit(5) == 1 # 001.....  table max size update
          raise Error.new("unexpected dynamic table size update") if decoded_header
          table_size_update_count =
            apply_dynamic_table_size_update(table_size_update_count)
          next
        elsif reader.current_byte.bit(4) == 1 # 0001....  literal never indexed
          _index, name, value = literal_never_indexed
          indexing = Indexing::NEVER
        else # 0000....  literal without indexing
          _index, name, value = literal_without_indexing
          indexing = Indexing::NONE
        end

        decoded_header = true
        headers.add(name, value)
        fields << DecodedHeader.new(name, value, indexing) if fields
      end

      @required_table_size_update = nil
      headers
    rescue ex : IndexError
      raise Error.new("invalid compression")
    end

    private def normalize_table_size(size : Int) : Int32
      if size < 0 || size > Int32::MAX
        raise ArgumentError.new(
          "table size must be between 0 and #{Int32::MAX}: #{size}"
        )
      end

      size.to_i32
    end

    @[AlwaysInline]
    private def ensure_required_table_size_update
      return unless @required_table_size_update
      unless reader.done?
        return if reader.current_byte & 0xe0_u8 == 0x20_u8
      end

      raise Error.new("required dynamic table size update is missing")
    end

    private def apply_dynamic_table_size_update(update_count : Int32)
      update_count += 1
      if update_count > 2
        raise Error.new("too many dynamic table size updates")
      end

      new_size = integer(5)
      if new_size > max_table_size
        raise Error.new(
          "dynamic table size update is larger than " \
          "SETTINGS_HEADER_TABLE_SIZE (#{max_table_size})"
        )
      end
      if update_count == 1
        if required_size = @required_table_size_update
          if new_size > required_size
            raise Error.new(
              "required dynamic table size update exceeds #{required_size}"
            )
          end
        end
      end

      table.resize(new_size)
      update_count
    end

    @[AlwaysInline]
    def literal_indexed
      index = integer(7)
      raise Error.new("invalid index: 0") if index == 0
      name, value = indexed(index)
      {index, name, value}
    end

    @[AlwaysInline]
    def literal_with_incremental_indexing
      index = integer(6)
      name = index == 0 ? string : indexed(index).first
      value = string
      table.add(name, value)
      {index, name, value}
    end

    @[AlwaysInline]
    def literal_never_indexed
      index = integer(4)
      name = index == 0 ? string : indexed(index).first
      value = string
      {index, name, value}
    end

    @[AlwaysInline]
    def literal_without_indexing
      index = integer(4)
      name = index == 0 ? string : indexed(index).first
      value = string
      {index, name, value}
    end

    def indexed(index)
      if 0 < index <= STATIC_TABLE_SIZE
        return STATIC_TABLE[index - 1]
      end

      if header = table[index - STATIC_TABLE_SIZE - 1]?
        return header
      end

      raise Error.new("invalid index: #{index}")
    end

    def integer(n)
      integer = (reader.read_byte & (0xff >> (8 - n))).to_i64
      prefix_maximum = (2_i64 ** n) - 1
      return integer.to_i32 if integer < prefix_maximum

      maximum = Int32::MAX.to_i64
      multiplier = 1_i64
      beyond_limit = false
      loop do
        byte = reader.read_byte
        digit = (byte & 127).to_i64
        if beyond_limit
          raise Error.new("integer exceeds implementation limit") unless digit == 0
        else
          increment = digit * multiplier
          if increment > maximum - integer
            raise Error.new("integer exceeds implementation limit")
          end
          integer += increment
        end
        break unless byte & 128 == 128

        if multiplier > maximum // 128
          beyond_limit = true
        else
          multiplier *= 128
        end
      end

      integer.to_i32
    end

    def string
      huffman = reader.current_byte.bit(7) == 1
      length = integer(7)
      bytes = reader.read(length)

      if huffman
        @huffman_output.clear
        HPack.huffman.decode(bytes, @huffman_output)
        @huffman_output.to_s
      else
        String.new(bytes)
      end
    end
  end
end
