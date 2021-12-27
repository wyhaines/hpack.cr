require "./indexing"
require "./dynamic_table"
require "./static_table"
require "./huffman"

module HPack
  struct Encoder
    # TODO: allow per header name/value indexing configuration
    # TODO: allow per header name/value huffman encoding configuration

    private getter! writer : IO::Memory
    getter table : DynamicTable
    property default_indexing : Indexing
    property default_huffman : Bool

    def initialize(indexing = Indexing::NONE, huffman = false, max_table_size = 4096)
      @default_indexing = indexing
      @default_huffman = huffman
      @table = DynamicTable.new(max_table_size)
    end

    def encode(
      headers : HTTP::Headers,
      indexing = default_indexing,
      huffman = default_huffman,
      @writer = IO::Memory.new
    )
      headers.each { |name, values| encode(name.downcase, values, indexing, huffman) if name.starts_with?(':') }
      headers.each { |name, values| encode(name.downcase, values, indexing, huffman) unless name.starts_with?(':') }
      writer.to_slice
    end

    def encode(name, values, indexing, huffman)
      values.each do |value|
        if header = indexed(name, value)
          if header[1]
            integer(header[0], 7, prefix: Indexing::INDEXED)
          elsif indexing == Indexing::ALWAYS
            integer(header[0], 6, prefix: Indexing::ALWAYS)
            string(value, huffman)
            table.add(name, value)
          else
            integer(header[0], 4, prefix: Indexing::NONE)
            string(value, huffman)
          end
        else
          case indexing
          when Indexing::ALWAYS
            table.add(name, value)
            writer.write_byte(Indexing::ALWAYS.value)
          when Indexing::NEVER
            writer.write_byte(Indexing::NEVER.value)
          else
            writer.write_byte(Indexing::NONE.value)
          end
          string(name, huffman)
          string(value, huffman)
        end
      end
    end

    protected def indexed(name, value)
      # TODO: This does full table scans every time it is called.
      # Optimize it to use some sort of cached lookup.
      # use a cached { name => { value => index } } struct (?)
      idx = nil

      if STATIC_TABLE_LOOKUP.has_key?({name, value})
        return {STATIC_TABLE_LOOKUP[{name, value}] + 1, value}
      elsif STATIC_TABLE_LOOKUP.has_key?({name, ""})
        idx = STATIC_TABLE_LOOKUP[{name, ""}] + 1
      else
        STATIC_TABLE.each_with_index do |header, index|
          if header[0] == name
            if header[1] == value
              return {index + 1, value}
            else
              idx ||= index + 1
            end
          end
        end
      end

      table.each_with_index do |header, index|
        if header[0] == name
          if header[1] == value
            return {index + STATIC_TABLE_SIZE + 1, value}
            # else
            #  idx ||= index + 1
          end
        end
      end

      if idx
        {idx, nil}
      end
    end

    protected def integer(integer : Int32, n, prefix = 0_u8)
      n2 = 2 ** n - 1

      if integer < n2
        writer.write_byte(integer.to_u8 | prefix.to_u8)
        return
      end

      writer.write_byte(n2.to_u8 | prefix.to_u8)
      integer -= n2

      while integer >= 128
        writer.write_byte(((integer % 128) + 128).to_u8)
        integer /= 128
      end

      writer.write_byte(integer.to_u8)
    end

    protected def string(string : String, huffman = false)
      if huffman
        encoded = HPack.huffman.encode(string)
        integer(encoded.size, 7, prefix: 128)
        writer.write(encoded)
      else
        integer(string.bytesize, 7)
        writer << string
      end
    end
  end
end
