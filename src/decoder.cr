require "./slice_reader"
require "./error"

module HPack
  # To decode headers, used a `HPack::Decoder` instance. By default, a decoder is created with a 4k (4096 bytes) table size. That table size can be changed in the constructor.
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
  struct Decoder
    private getter! reader : SliceReader
    getter table : DynamicTable
    property max_table_size : Int32

    def initialize(@max_table_size = 4096)
      @table = DynamicTable.new(@max_table_size)
    end

    def decode(bytes, headers = HTTP::Headers.new)
      @reader = SliceReader.new(bytes)
      decoded_common_headers = false

      until reader.done?
        if reader.current_byte.bit(7) == 1 # 1.......  indexed
          index, name, value = literal_indexed
        elsif reader.current_byte.bit(6) == 1 # 01......  literal with incremental indexing
          index, name, value = literal_with_incremental_indexing
        elsif reader.current_byte.bit(5) == 1 # 001.....  table max size update
          raise Error.new("unexpected dynamic table size update") if decoded_common_headers
          if (new_size = integer(5)) > max_table_size
            raise Error.new("dynamic table size update is larger than SETTINGS_HEADER_TABLE_SIZE(#{max_table_size}")
          end
          table.resize(new_size)
          next
        elsif reader.current_byte.bit(4) == 1 # 0001....  literal never indexed
          index, name, value = literal_never_indexed
          # TODO: retain the never_indexed property
        else # 0000....  literal without indexing
          index, name, value = literal_without_indexing
        end

        decoded_common_headers = 0 < index < STATIC_TABLE_SIZE
        headers.add(name, value)
      end

      headers
    rescue ex : IndexError
      raise Error.new("invalid compression")
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
      if 0 < index < STATIC_TABLE_SIZE
        return STATIC_TABLE[index - 1]
      end

      if header = table[index - STATIC_TABLE_SIZE - 1]?
        return header
      end

      raise Error.new("invalid index: #{index}")
    end

    def integer(n)
      integer = (reader.read_byte & (0xff >> (8 - n))).to_i
      n2 = 2 ** n - 1
      return integer if integer < n2

      m = 0
      loop do
        # TODO: raise if integer grows over limit
        byte = reader.read_byte
        integer += (byte & 127).to_i * (2 ** (m * 7))
        break unless byte & 128 == 128
        m += 1
      end

      integer
    end

    def string
      huffman = reader.current_byte.bit(7) == 1
      length = integer(7)
      bytes = reader.read(length)

      if huffman
        HPack.huffman.decode(bytes)
      else
        String.new(bytes)
      end
    end
  end
end
