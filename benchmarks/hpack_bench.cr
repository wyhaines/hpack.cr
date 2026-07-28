require "benchmark"
require "../src/hpack"

# Representative request + response header sets (mix of static hits,
# dynamic-table hits after warmup, and literal strings).
REQUEST_HEADERS = [
  {":method", "GET"}, {":scheme", "https"}, {":path", "/api/v1/users?page=2"},
  {":authority", "api.example.com"}, {"accept", "application/json"},
  {"accept-encoding", "gzip, deflate, br"}, {"user-agent", "bench-client/1.0"},
  {"x-request-id", "4f9a1c2e-77b3-4b9d-9e51-0a8b3c6d2f10"},
  {"cookie", "session=abcdef0123456789; theme=dark"},
]

encoder = HPack::Encoder.new(indexing: HPack::Indexing::ALWAYS, huffman: true)
decoder = HPack::Decoder.new

# Warm the dynamic tables, and capture one encoded block for decode bench.
encoded = Bytes.empty
3.times do
  encoded = encoder.encode(REQUEST_HEADERS.map { |(n, v)| HPack::HeaderField.new(n, v) })
  decoder.decode(encoded)
end

Benchmark.ips do |x|
  x.report("encode 9-field block") do
    encoder.encode(REQUEST_HEADERS.map { |(n, v)| HPack::HeaderField.new(n, v) })
  end
  x.report("decode 9-field block") do
    decoder.decode(encoded)
  end
end
