require "./support"

module HPackBench
  module Fixtures
    extend self

    record HuffmanFixture, label : String, input : String

    SHORT_ASCII     = "hello"
    HTTP_VALUE      = "foo=asdfasdfasdfasdfasdfasdfasdf; max-age=3600; version=1"
    LONG_ASCII      = "abcdefghijklmnopqrstuvwxyz012345" * 32
    ALL_BYTES       = String.new(Bytes.new(256, &.to_u8))
    EXPANDING       = "!"
    VERY_LONG_ASCII = "www.example.com/" * 512
    HIGH_BYTES      = String.new(Bytes.new(1024) { |index| (128 + index % 128).to_u8 })

    RFC_HUFFMAN_WWW = Bytes[
      0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a,
      0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff,
    ]

    RFC_REQUEST_1 = Bytes[
      0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2,
      0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4,
      0xff,
    ]

    RFC_REQUEST_2 = Bytes[
      0x82, 0x86, 0x84, 0xbe, 0x58, 0x86,
      0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf,
    ]

    RFC_REQUEST_3 = Bytes[
      0x82, 0x87, 0x85, 0xbf, 0x40, 0x88, 0x25, 0xa8,
      0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f, 0x89, 0x25,
      0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf,
    ]

    STATIC_REQUEST = Bytes[0x82, 0x86, 0x84]

    RAW_LITERAL = Bytes[
      0x04, 0x0c, 0x2f, 0x73, 0x61, 0x6d, 0x70,
      0x6c, 0x65, 0x2f, 0x70, 0x61, 0x74, 0x68,
    ]

    TABLE_SIZE_UPDATE = Bytes[0x20, 0x82]

    NEVER_INDEXED = Bytes[
      0x82, 0x1f, 0x08, 0x06, 0x73,
      0x65, 0x63, 0x72, 0x65, 0x74,
    ]

    def default_huffman
      [
        HuffmanFixture.new("short ASCII", SHORT_ASCII),
        HuffmanFixture.new("HTTP value", HTTP_VALUE),
        HuffmanFixture.new("long ASCII", LONG_ASCII),
        HuffmanFixture.new("all byte values", ALL_BYTES),
        HuffmanFixture.new("expanding input", EXPANDING),
      ]
    end

    def extended_huffman
      default_huffman + [
        HuffmanFixture.new("empty", ""),
        HuffmanFixture.new("very long ASCII", VERY_LONG_ASCII),
        HuffmanFixture.new("high bytes repeated", HIGH_BYTES),
      ]
    end

    def literal_headers(name = "x-benchmark", value = HTTP_VALUE)
      HTTP::Headers{name => value}
    end

    def multiple_value_headers
      HTTP::Headers{
        "x-benchmark" => ["first", "second", "third"],
      }
    end

    def response_headers
      HTTP::Headers{
        ":status"          => "200",
        "cache-control"    => "private",
        "date"             => "Mon, 21 Oct 2013 20:13:22 GMT",
        "location"         => "https://www.example.com",
        "content-encoding" => "gzip",
        "set-cookie"       => HTTP_VALUE,
      }
    end

    def response_fields
      [
        {":status", "200"},
        {"cache-control", "private"},
        {"date", "Mon, 21 Oct 2013 20:13:22 GMT"},
        {"location", "https://www.example.com"},
        {"content-encoding", "gzip"},
        {"set-cookie", HTTP_VALUE},
      ]
    end

    def static_request_headers
      HTTP::Headers{
        ":method" => "GET",
        ":scheme" => "http",
        ":path"   => "/",
      }
    end

    def rfc_request_1_headers
      HTTP::Headers{
        ":method"    => "GET",
        ":scheme"    => "http",
        ":path"      => "/",
        ":authority" => "www.example.com",
      }
    end

    def rfc_request_2_headers
      HTTP::Headers{
        ":method"       => "GET",
        ":scheme"       => "http",
        ":path"         => "/",
        ":authority"    => "www.example.com",
        "cache-control" => "no-cache",
      }
    end

    def rfc_request_3_headers
      HTTP::Headers{
        ":method"    => "GET",
        ":scheme"    => "https",
        ":path"      => "/index.html",
        ":authority" => "www.example.com",
        "custom-key" => "custom-value",
      }
    end
  end
end
