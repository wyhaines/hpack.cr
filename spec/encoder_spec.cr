require "./spec_helper"

describe HPack::Encoder do
  encoder = uninitialized HPack::Encoder

  before_each do
    encoder = HPack::Encoder.new
  end

  it "can work with literal headers with Indexing::ALWAYS" do
    headers = HTTP::Headers{"custom-key" => "custom-header"}
    encoder.encode(headers, HPack::Indexing::ALWAYS).should eq UInt8.static_array(0x40, 0x0a, 0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x2d,
      0x6b, 0x65, 0x79, 0x0d, 0x63, 0x75, 0x73, 0x74, 0x6f,
      0x6d, 0x2d, 0x68, 0x65, 0x61, 0x64, 0x65, 0x72).to_slice

    encoder.table.size.should eq 1
    encoder.table.bytesize.should eq 55
    encoder.table[0].should eq ({"custom-key", "custom-header"})
  end

  it "can work with literal headers with Indexing::NONE" do
    headers = HTTP::Headers{":path" => "/sample/path"}
    encoder.encode(headers, HPack::Indexing::NONE).should eq UInt8.static_array(0x04, 0x0c, 0x2f, 0x73, 0x61, 0x6d, 0x70, 0x6c, 0x65,
      0x2f, 0x70, 0x61, 0x74, 0x68).to_slice

    encoder.table.size.should eq 0
  end

  it "can work with literal headers with Indexing::NEVER" do
    headers = HTTP::Headers{"password" => "secret"}
    encoder.encode(headers, HPack::Indexing::NEVER).should eq UInt8.static_array(0x10, 0x08, 0x70, 0x61, 0x73, 0x73, 0x77, 0x6f, 0x72,
      0x64, 0x06, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74).to_slice
    encoder.table.size.should eq 0
  end

  it "sets a GET method header value correctly" do
    encoder.encode(HTTP::Headers{":method" => "GET"}).should eq UInt8.static_array(0x82).to_slice

    encoder.table.size.should eq 0
  end

  it "works with a large integer literal" do
    bytes = encoder.encode(
      HTTP::Headers{"x-dummy1" => "." * 4096},
      HPack::Indexing::NONE,
      huffman: false)
    bytes[0, 10].should eq UInt8.static_array(0x00, 0x08, 'x'.ord, '-'.ord, 'd'.ord, 'u'.ord, 'm'.ord, 'm'.ord, 'y'.ord, '1'.ord).to_slice
    bytes[10, 3].should eq UInt8.static_array(0x7f, 0x81, 0x1f).to_slice
    bytes[13, bytes.size - 13].should eq ("." * 4096).to_slice
  end

  it "works with a small integer literal" do
    bytes = encoder.encode(
      HTTP::Headers{"x-dummy1" => "." * 127},
      HPack::Indexing::NONE,
      huffman: false)
    UInt8.static_array(0x7f, 0x00).to_slice.should eq bytes[10, 2]
    ("." * 127).to_slice.should eq bytes[12, bytes.size - 12]
  end

  it "should always encode special headers first" do
    encoder = HPack::Encoder.new(
      indexing: HPack::Indexing::ALWAYS,
      huffman: false)
    headers = HTTP::Headers{
      "cache-control" => "private",
      ":status"       => "302",
    }
    UInt8.static_array(
      0x48, 0x03, 0x33, 0x30, 0x32, 0x58, 0x07, 0x70, 0x72, 0x69, 0x76, 0x61, 0x74, 0x65,
    ).to_slice.should eq encoder.encode(headers)
  end

  # # http://tools.ietf.org/html/rfc7541#appendix-C.5
  it "should work without huffman encodeing" do
    encoder = HPack::Encoder.new(
      max_table_size: 256,
      indexing: HPack::Indexing::ALWAYS,
      huffman: false)

    # first response:  http://tools.ietf.org/html/rfc7541#appendix-C.5.1
    headers = HTTP::Headers{
      ":status"       => "302",
      "cache-control" => "private",
      "date"          => "Mon, 21 Oct 2013 20:13:21 GMT",
      "location"      => "https://www.example.com",
    }
    UInt8.static_array(
      0x48, 0x03, 0x33, 0x30, 0x32,
      0x58, 0x07, 0x70, 0x72, 0x69, 0x76, 0x61, 0x74, 0x65,
      0x61, 0x1d, 0x4d, 0x6f, 0x6e, 0x2c, 0x20, 0x32, 0x31, 0x20, 0x4f, 0x63, 0x74, 0x20, 0x32, 0x30, 0x31, 0x33, 0x20, 0x32, 0x30, 0x3a, 0x31, 0x33, 0x3a, 0x32, 0x31, 0x20, 0x47, 0x4d, 0x54,
      0x6e, 0x17, 0x68, 0x74, 0x74, 0x70, 0x73, 0x3a, 0x2f, 0x2f, 0x77, 0x77, 0x77, 0x2e, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x2e, 0x63, 0x6f, 0x6d
    ).to_slice.should eq encoder.encode(headers)

    encoder.table.size.should eq 4
    encoder.table.bytesize.should eq 222
    {"location", "https://www.example.com"}.should eq encoder.table[0]
    {"date", "Mon, 21 Oct 2013 20:13:21 GMT"}.should eq encoder.table[1]
    {"cache-control", "private"}.should eq encoder.table[2]
    {":status", "302"}.should eq encoder.table[3]

    # second response:  http://tools.ietf.org/html/rfc7541#appendix-C.5.2
    headers = HTTP::Headers{
      ":status"       => "307",
      "cache-control" => "private",
      "date"          => "Mon, 21 Oct 2013 20:13:21 GMT",
      "location"      => "https://www.example.com",
    }
    UInt8.static_array(0x48, 0x03, 0x33, 0x30, 0x37, 0xc1, 0xc0, 0xbf).to_slice.should eq encoder.encode(headers)

    encoder.table.size.should eq 4
    encoder.table.bytesize.should eq 222
    {":status", "307"}.should eq encoder.table[0]
    {"location", "https://www.example.com"}.should eq encoder.table[1]
    {"date", "Mon, 21 Oct 2013 20:13:21 GMT"}.should eq encoder.table[2]
    {"cache-control", "private"}.should eq encoder.table[3]

    # third response:  http://tools.ietf.org/html/rfc7541#appendix-C.5.3
    headers = HTTP::Headers{
      ":status"          => "200",
      "cache-control"    => "private",
      "date"             => "Mon, 21 Oct 2013 20:13:22 GMT",
      "location"         => "https://www.example.com",
      "content-encoding" => "gzip",
      "set-cookie"       => "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1",
    }
    UInt8.static_array(
      0x88, 0xc1, 0x61, 0x1d, 0x4d, 0x6f, 0x6e, 0x2c, 0x20,
      0x32, 0x31, 0x20, 0x4f, 0x63, 0x74, 0x20, 0x32, 0x30,
      0x31, 0x33, 0x20, 0x32, 0x30, 0x3a, 0x31, 0x33, 0x3a,
      0x32, 0x32, 0x20, 0x47, 0x4d, 0x54, 0xc0, 0x5a, 0x04,
      0x67, 0x7a, 0x69, 0x70, 0x77, 0x38, 0x66, 0x6f, 0x6f,
      0x3d, 0x41, 0x53, 0x44, 0x4a, 0x4b, 0x48, 0x51, 0x4b,
      0x42, 0x5a, 0x58, 0x4f, 0x51, 0x57, 0x45, 0x4f, 0x50,
      0x49, 0x55, 0x41, 0x58, 0x51, 0x57, 0x45, 0x4f, 0x49,
      0x55, 0x3b, 0x20, 0x6d, 0x61, 0x78, 0x2d, 0x61, 0x67,
      0x65, 0x3d, 0x33, 0x36, 0x30, 0x30, 0x3b, 0x20, 0x76,
      0x65, 0x72, 0x73, 0x69, 0x6f, 0x6e, 0x3d, 0x31
    ).to_slice.should eq encoder.encode(headers)

    encoder.table.size.should eq 3
    encoder.table.bytesize.should eq 215
    {"set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"}.should eq encoder.table[0]
    {"content-encoding", "gzip"}.should eq encoder.table[1]
    {"date", "Mon, 21 Oct 2013 20:13:22 GMT"}.should eq encoder.table[2]
  end

  # # http://tools.ietf.org/html/rfc7541#appendix-C.6
  it "should work with huffman encoding" do
    encoder = HPack::Encoder.new(
      max_table_size: 256,
      indexing: HPack::Indexing::ALWAYS,
      huffman: true)

    # first response:  http://tools.ietf.org/html/rfc7541#appendix-C.6.1
    headers = HTTP::Headers{
      ":status"       => "302",
      "cache-control" => "private",
      "date"          => "Mon, 21 Oct 2013 20:13:21 GMT",
      "location"      => "https://www.example.com",
    }
    UInt8.static_array(
      0x48, 0x82, 0x64, 0x02, 0x58, 0x85, 0xae, 0xc3, 0x77,
      0x1a, 0x4b, 0x61, 0x96, 0xd0, 0x7a, 0xbe, 0x94, 0x10,
      0x54, 0xd4, 0x44, 0xa8, 0x20, 0x05, 0x95, 0x04, 0x0b,
      0x81, 0x66, 0xe0, 0x82, 0xa6, 0x2d, 0x1b, 0xff, 0x6e,
      0x91, 0x9d, 0x29, 0xad, 0x17, 0x18, 0x63, 0xc7, 0x8f,
      0x0b, 0x97, 0xc8, 0xe9, 0xae, 0x82, 0xae, 0x43, 0xd3
    ).to_slice.should eq encoder.encode(headers)

    encoder.table.size.should eq 4
    encoder.table.bytesize.should eq 222
    {"location", "https://www.example.com"}.should eq encoder.table[0]
    {"date", "Mon, 21 Oct 2013 20:13:21 GMT"}.should eq encoder.table[1]
    {"cache-control", "private"}.should eq encoder.table[2]
    {":status", "302"}.should eq encoder.table[3]

    # second response:  http://tools.ietf.org/html/rfc7541#appendix-C.6.2
    headers = HTTP::Headers{
      ":status"       => "307",
      "cache-control" => "private",
      "date"          => "Mon, 21 Oct 2013 20:13:21 GMT",
      "location"      => "https://www.example.com",
    }
    UInt8.static_array(
      0x48, 0x83, 0x64, 0x0e, 0xff, 0xc1, 0xc0, 0xbf
    ).to_slice.should eq encoder.encode(headers)

    encoder.table.size.should eq 4
    encoder.table.bytesize.should eq 222
    {":status", "307"}.should eq encoder.table[0]
    {"location", "https://www.example.com"}.should eq encoder.table[1]
    {"date", "Mon, 21 Oct 2013 20:13:21 GMT"}.should eq encoder.table[2]
    {"cache-control", "private"}.should eq encoder.table[3]

    # third response:  http://tools.ietf.org/html/rfc7541#appendix-C.6.3
    headers = HTTP::Headers{
      ":status"          => "200",
      "cache-control"    => "private",
      "date"             => "Mon, 21 Oct 2013 20:13:22 GMT",
      "location"         => "https://www.example.com",
      "content-encoding" => "gzip",
      "set-cookie"       => "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1",
    }
    UInt8.static_array(
      0x88, 0xc1, 0x61, 0x96, 0xd0, 0x7a, 0xbe, 0x94, 0x10,
      0x54, 0xd4, 0x44, 0xa8, 0x20, 0x05, 0x95, 0x04, 0x0b,
      0x81, 0x66, 0xe0, 0x84, 0xa6, 0x2d, 0x1b, 0xff, 0xc0,
      0x5a, 0x83, 0x9b, 0xd9, 0xab, 0x77, 0xad, 0x94, 0xe7,
      0x82, 0x1d, 0xd7, 0xf2, 0xe6, 0xc7, 0xb3, 0x35, 0xdf,
      0xdf, 0xcd, 0x5b, 0x39, 0x60, 0xd5, 0xaf, 0x27, 0x08,
      0x7f, 0x36, 0x72, 0xc1, 0xab, 0x27, 0x0f, 0xb5, 0x29,
      0x1f, 0x95, 0x87, 0x31, 0x60, 0x65, 0xc0, 0x03, 0xed,
      0x4e, 0xe5, 0xb1, 0x06, 0x3d, 0x50, 0x07
    ).to_slice.should eq encoder.encode(headers)

    encoder.table.size.should eq 3
    encoder.table.bytesize.should eq 215
    {"set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"}.should eq encoder.table[0]
    {"content-encoding", "gzip"}.should eq encoder.table[1]
    {"date", "Mon, 21 Oct 2013 20:13:22 GMT"}.should eq encoder.table[2]
  end
end
