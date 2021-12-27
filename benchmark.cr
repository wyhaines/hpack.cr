# This is a very simple benchmark. It is mostly useful during development to manually
# test against performance regressions while working on optimizations.
# To run it:
#
# crystal run -p -s -t --release benchmark.cr
#

require "benchmark"
require "http/headers"
require "./src/hpack"

encoder = HPack::Encoder.new(
  max_table_size: 4096,
  indexing: HPack::Indexing::ALWAYS,
  huffman: true)

decoder = HPack::Decoder.new

bytes1 = UInt8.static_array(
  0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2,
  0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4,
  0xff).to_slice

bytes2 = UInt8.static_array(
  0x82, 0x86, 0x84, 0xbe, 0x58, 0x86, 0xa8, 0xeb,
  0x10, 0x64, 0x9c, 0xbf).to_slice

bytes3 = UInt8.static_array(
  0x82, 0x87, 0x85, 0xbf, 0x40, 0x88, 0x25, 0xa8,
  0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f, 0x89, 0x25,
  0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf).to_slice

headers = HTTP::Headers{
  ":status"          => "200",
  "cache-control"    => "private",
  "date"             => "Mon, 21 Oct 2013 20:13:22 GMT",
  "location"         => "https://www.example.com",
  "content-encoding" => "gzip",
  "set-cookie"       => "foo=asdfasdfasdfasdfasdfasdfasdf; max-age=3600; version=1",
}

Benchmark.ips do |bm|
  bm.report("optimized encoder") do
    encoder.encode(headers)
  end
  bm.report("optimized decoder") do
    decoder.decode bytes1
    decoder.decode bytes2
    decoder.decode bytes3
  end
end
