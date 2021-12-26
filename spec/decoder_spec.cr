require "./spec_helper"

describe HPack::Decoder do
  decoder = uninitialized HPack::Decoder

  before_each do
    decoder = HPack::Decoder.new
  end

  # http://tools.ietf.org/html/rfc7541#appendix-C.2.1
  it "literal header with indexing works" do
    headers = decoder.decode(
      UInt8.static_array(
        0x40, 0x0a, 0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d,
        0x2d, 0x6b, 0x65, 0x79, 0x0d, 0x63, 0x75, 0x73,
        0x74, 0x6f, 0x6d, 0x2d, 0x68, 0x65, 0x61, 0x64,
        0x65, 0x72).to_slice)
    HTTP::Headers{"custom-key" => "custom-header"}.should eq headers
    decoder.table.size.should eq 1
    {"custom-key", "custom-header"}.should eq decoder.indexed(62)
    decoder.table.bytesize.should eq 55
  end

  # # http://tools.ietf.org/html/rfc7541#appendix-C.2.2
  it "works with a literal header without indexing" do
    headers = decoder.decode(
      UInt8.static_array(
        0x04, 0x0c, 0x2f, 0x73, 0x61, 0x6d, 0x70, 0x6c,
        0x65, 0x2f, 0x70, 0x61, 0x74, 0x68).to_slice)
    HTTP::Headers{":path" => "/sample/path"}.should eq headers
    decoder.table.size.should eq 0
  end

  # # http://tools.ietf.org/html/rfc7541#appendix-C.2.3
  it "works with a literal header that is never indexed" do
    headers = decoder.decode(
      UInt8.static_array(
        0x10, 0x08, 0x70, 0x61, 0x73, 0x73, 0x77, 0x6f,
        0x72, 0x64, 0x06, 0x73, 0x65, 0x63, 0x72, 0x65,
        0x74).to_slice)
    HTTP::Headers{"password" => "secret"}.should eq headers
    decoder.table.size.should eq 0
  end

  # # http://tools.ietf.org/html/rfc7541#appendix-C.2.4
  it "works with an indexed header field" do
    HTTP::Headers{":method" => "GET"}.should eq decoder.decode(UInt8.static_array(0x82).to_slice)
    decoder.table.size.should eq 0
  end

  # # http://tools.ietf.org/html/rfc7541#appendix-C.3
  it "works without huffman encoding" do
    # first request: http://tools.ietf.org/html/rfc7541#appendix-C.3.1
    headers = decoder.decode(
      UInt8.static_array(0x82, 0x86, 0x84, 0x41, 0x0f, 0x77, 0x77, 0x77,
        0x2e, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65,
        0x2e, 0x63, 0x6f, 0x6d).to_slice)
    HTTP::Headers{
      ":method"    => "GET",
      ":scheme"    => "http",
      ":path"      => "/",
      ":authority" => "www.example.com",
    }.should eq headers

    decoder.table.size.should eq 1
    decoder.table.bytesize.should eq 57
    {":authority", "www.example.com"}.should eq decoder.indexed(62)

    # second request: http://tools.ietf.org/html/rfc7541#appendix-C.3.2
    headers = decoder.decode(
      UInt8.static_array(0x82, 0x86, 0x84, 0xbe, 0x58, 0x08, 0x6e, 0x6f,
        0x2d, 0x63, 0x61, 0x63, 0x68, 0x65).to_slice)
    HTTP::Headers{
      ":method"       => "GET",
      ":scheme"       => "http",
      ":path"         => "/",
      ":authority"    => "www.example.com",
      "cache-control" => "no-cache",
    }.should eq headers

    decoder.table.size.should eq 2
    decoder.table.bytesize.should eq 110
    {"cache-control", "no-cache"}.should eq decoder.indexed(62)
    {":authority", "www.example.com"}.should eq decoder.indexed(63)

    # third request: http://tools.ietf.org/html/rfc7541#appendix-C.3.3
    headers = decoder.decode(
      UInt8.static_array(
        0x82, 0x87, 0x85, 0xbf, 0x40, 0x0a, 0x63, 0x75,
        0x73, 0x74, 0x6f, 0x6d, 0x2d, 0x6b, 0x65, 0x79,
        0x0c, 0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x2d,
        0x76, 0x61, 0x6c, 0x75, 0x65).to_slice)
    HTTP::Headers{
      ":method"    => "GET",
      ":scheme"    => "https",
      ":path"      => "/index.html",
      ":authority" => "www.example.com",
      "custom-key" => "custom-value",
    }.should eq headers

    decoder.table.size.should eq 3
    decoder.table.bytesize.should eq 164
    {"custom-key", "custom-value"}.should eq decoder.indexed(62)
    {"cache-control", "no-cache"}.should eq decoder.indexed(63)
    {":authority", "www.example.com"}.should eq decoder.indexed(64)
  end

  # # http://tools.ietf.org/html/rfc7541#appendix-C.4
  it "works with huffman encoding" do
    # first request: http://tools.ietf.org/html/rfc7541#appendix-C.4.1
    headers = decoder.decode(
      UInt8.static_array(
        0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2,
        0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4,
        0xff).to_slice)
    HTTP::Headers{
      ":method"    => "GET",
      ":scheme"    => "http",
      ":path"      => "/",
      ":authority" => "www.example.com",
    }.should eq headers

    decoder.table.size.should eq 1
    decoder.table.bytesize.should eq 57
    {":authority", "www.example.com"}.should eq decoder.indexed(62)
    {":authority", "www.example.com"}.should eq decoder.indexed(62)

    # second request: http://tools.ietf.org/html/rfc7541#appendix-C.4.2
    headers = decoder.decode(
      UInt8.static_array(
        0x82, 0x86, 0x84, 0xbe, 0x58, 0x86, 0xa8, 0xeb,
        0x10, 0x64, 0x9c, 0xbf).to_slice)
    HTTP::Headers{
      ":method"       => "GET",
      ":scheme"       => "http",
      ":path"         => "/",
      ":authority"    => "www.example.com",
      "cache-control" => "no-cache",
    }.should eq headers

    decoder.table.size.should eq 2
    decoder.table.bytesize.should eq 110
    {"cache-control", "no-cache"}.should eq decoder.indexed(62)
    {":authority", "www.example.com"}.should eq decoder.indexed(63)

    # third request: http://tools.ietf.org/html/rfc7541#appendix-C.4.3
    headers = decoder.decode(
      UInt8.static_array(
        0x82, 0x87, 0x85, 0xbf, 0x40, 0x88, 0x25, 0xa8,
        0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f, 0x89, 0x25,
        0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf).to_slice)
    HTTP::Headers{
      ":method"    => "GET",
      ":scheme"    => "https",
      ":path"      => "/index.html",
      ":authority" => "www.example.com",
      "custom-key" => "custom-value",
    }.should eq headers

    decoder.table.size.should eq 3
    decoder.table.bytesize.should eq 164
    {"custom-key", "custom-value"}.should eq decoder.indexed(62)
    {"cache-control", "no-cache"}.should eq decoder.indexed(63)
    {":authority", "www.example.com"}.should eq decoder.indexed(64)
  end

  it "works with large integer literals" do
    bytes = Slice(UInt8).new(3 + 3 + 4096) { '.'.ord.to_u8 }
    bytes[0] = 0x00_u8
    bytes[1] = 0x01_u8
    bytes[2] = 'x'.ord.to_u8
    bytes[3] = 0x7f_u8
    bytes[4] = 0x81_u8
    bytes[5] = 0x1f_u8

    headers = decoder.decode(bytes)
    ("." * 4096).should eq headers["x"]
  end

  it "works with a smaller integer literal" do
    bytes = Slice(UInt8).new(3 + 2 + 127) { '.'.ord.to_u8 }
    bytes[0] = 0x00_u8
    bytes[1] = 0x01_u8
    bytes[2] = 'x'.ord.to_u8
    bytes[3] = 0x7f_u8
    bytes[4] = 0x00_u8

    headers = decoder.decode(bytes)
    ("." * 127).should eq headers["x"]
  end

  # # https://tools.ietf.org/html/rfc7541#section-5.2
  it "should reject padding larger than 7 bits" do
    bytes = UInt8.static_array(
      0x82, 0x87, 0x84, 0x41, 0x8a, 0x08, 0x9d, 0x5c,
      0x0b, 0x81, 0x70, 0xdc, 0x7c, 0x4f, 0x8b, 0x00,
      0x85, 0xf2, 0xb2, 0x4a, 0x84, 0xff, 0x84, 0x49,
      0x50, 0x9f, 0xff).to_slice
    expect_raises(Exception) { decoder.decode(bytes) }
  end

  # # https://tools.ietf.org/html/rfc7541#section-5.2
  it "should reject non-EOS padding" do
    bytes = UInt8.static_array(
      0x82, 0x87, 0x84, 0x41, 0x8a, 0x08, 0x9d, 0x5c,
      0x0b, 0x81, 0x70, 0xdc, 0x7c, 0x4f, 0x8b, 0x00,
      0x85, 0xf2, 0xb2, 0x4a, 0x84, 0xff, 0x83, 0x49,
      0x50, 0x90).to_slice
    expect_raises(Exception) { decoder.decode(bytes) }
  end
end
