require "./indexing"
require "./dynamic_table"
require "./static_table"
require "./huffman"
{% if flag?(:preview_mt) %}
  require "mutex"
{% end %}

module HPack
  # The default Encoder will be created with Indexing set to [`NONE`](https://httpwg.org/specs/rfc7541.html#literal.header.without.indexing), huffman encoding false, and the max table size set to 4k (4096 bytes). These parameters can all be set in the constructor.
  #
  # ```
  # # To create a default Encoder:
  # encoder = HPack::Encoder.new
  #
  # # To create an encoder with indexing set to Always and Huffamn encoding set to true:
  # encoder = HPack::Encoder.new(indexing: HPack::Indexing::ALWAYS, huffman: true)
  # encoder = HPack::Encoder.new(HPack::Indexing::ALWAYS, true)
  #
  # # To create an encoder with the max table size set to 8k (8096 bytes):
  # encoder = HPack::Encoder.new(HPack::Indexing::ALWAYS, true, 8096)
  #
  # # To encode headers:
  # encoder.encode(
  #   HTTP::Headers{
  #     ":status"       => "302",
  #     "cache-control" => "private",
  #     "date"          => "Mon, 21 Oct 2013 20:13:21 GMT",
  #     "location"      => "https://www.example.com",
  #   }
  # )
  # ```
  struct Encoder
    # TODO: allow per header name/value indexing configuration
    # TODO: allow per header name/value huffman encoding configuration

    private getter writer : IO::Memory = IO::Memory.new
    @saved_writer : IO::Memory
    getter table : DynamicTable
    property default_indexing : Indexing
    property default_huffman : Bool
    {% if flag?(:preview_mt) %}
      @mutex = Mutex.new
    {% end %}

    def initialize(indexing = Indexing::NONE, huffman = false, max_table_size = 4096)
      @saved_writer = @writer
      @default_indexing = indexing
      @default_huffman = huffman
      @table = DynamicTable.new(max_table_size)
    end

    def encode(
      headers : HTTP::Headers,
      indexing = default_indexing,
      huffman = default_huffman,
      _writer : IO::Memory? = nil
    )
      {% begin %}
      {% if flag?(:preview_mt) %}
      @mutex.synchronize do
      {% end %}
      # If a pre-existing writer is provided, use it.
      if _writer
        @writer = _writer
      else
        @writer.clear
      end
      headers.each { |name, values| encode(name.downcase, values, indexing, huffman) if name.starts_with?(':') }
      headers.each { |name, values| encode(name.downcase, values, indexing, huffman) unless name.starts_with?(':') }

      # Restore the pre-existing writer.
      if _writer
        @writer = @saved_writer
        _writer.to_slice
      else
        @writer.to_slice
      end
      {% if flag?(:preview_mt) %}
      end
      {% end %}
      {% end %}
    end

    # :nodoc:
    protected def encode(name, values, indexing, huffman)
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

    # ameba:disable Metrics/CyclomaticComplexity
    protected def indexed(name, value)
      # This is WAY faster than iterating through the lookup table, or using a
      # hash based lookup table.
      # It could be optimized more by doing some statistical analysis on real
      # traffic in order to determine which headers are most common, and putting
      # them at the top of the case statement.

      # TODO: Can this case be built with a macro using the STATIC_TABLE instead
      # of just hardcoding it here and leaving the STATIC_TABLE unreferenced?
      idx = case name
            when ":authority"
              1
            when ":method"
              case value
              when "GET"
                return {2, "GET"}
              when "POST"
                return {3, "POST"}
              else
                3
              end
            when ":path"
              case value
              when "/"
                return {4, "/"}
              when "/index.html"
                return {5, "/index.html"}
              else
                4
              end
            when ":scheme"
              case value
              when "http"
                return {6, "http"}
              when "https"
                return {7, "https"}
              else
                6
              end
            when ":status"
              case value
              when "200"
                return {8, "200"}
              when "204"
                return {9, "204"}
              when "206"
                return {10, "206"}
              when "304"
                return {11, "304"}
              when "400"
                return {12, "400"}
              when "404"
                return {13, "404"}
              when "500"
                return {14, "500"}
              else
                8
              end
            when "accept-charset"
              15
            when "accept-encoding"
              case value
              when "gzip, deflate"
                return {16, "gzip, deflate"}
              else
                16
              end
            when "accept-language"
              17
            when "accept-ranges"
              18
            when "accept"
              19
            when "access-control-allow-origin"
              20
            when "age"
              21
            when "allow"
              22
            when "authorization"
              23
            when "cache-control"
              24
            when "content-disposition"
              25
            when "content-encoding"
              26
            when "content-language"
              27
            when "content-length"
              28
            when "content-location"
              29
            when "content-range"
              30
            when "content-type"
              31
            when "cookie"
              32
            when "date"
              33
            when "etag"
              34
            when "expect"
              35
            when "expires"
              36
            when "from"
              37
            when "host"
              38
            when "if-match"
              39
            when "if-modified-since"
              40
            when "if-none-match"
              41
            when "if-range"
              42
            when "if-unmodified-since"
              43
            when "last-modified"
              44
            when "link"
              45
            when "location"
              46
            when "max-forwards"
              47
            when "proxy-authenticate"
              48
            when "proxy-authorization"
              49
            when "range"
              50
            when "referer"
              51
            when "refresh"
              52
            when "retry-after"
              53
            when "server"
              54
            when "set-cookie"
              55
            when "strict-transport-security"
              56
            when "transfer-encoding"
              57
            when "user-agent"
              58
            when "vary"
              59
            when "via"
              60
            when "www-authenticate"
              61
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

    # ameba:disable Metrics/CyclomaticComplexity
    protected def integer(integer : Int32, n, prefix = 0_u8)
      # For this small set of results, a case statement is vastly faster than doing math.
      n2 = case n
           when 0
             0
           when 1
             1
           when 2
             3
           when 3
             7
           when 4
             15
           when 5
             31
           when 6
             63
           when 7
             127
           else
             # I don't think this will ever get called.
             2 ** n - 1
           end

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
