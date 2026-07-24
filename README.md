# hpack

![Send.cr CI](https://img.shields.io/github/workflow/status/wyhaines/hpack.cr/HPack%20CI?style=for-the-badge&logo=GitHub)
[![GitHub release](https://img.shields.io/github/release/wyhaines/hpack.cr.svg?style=for-the-badge)](https://github.com/wyhaines/hpack.cr/releases)
![GitHub commits since latest release (by SemVer)](https://img.shields.io/github/commits-since/wyhaines/hpack.cr/latest?style=for-the-badge)

This shard provides a standalone, pure Crystal [HPack](https://httpwg.org/specs/rfc7541.html) implementation. HPack is a Huffman-based header compression format that is used with HTTP/2.

This implementation is based on [@ysbaddaden](https://github.com/ysbaddaden)'s implementation that is bundled inside of his [http2](https://github.com/ysbaddaden/http2) server & client shard, with some modest refactoring and significant improvements, packaged and maintained for current Crystal versions.

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     hpack:
       github: wyhaines/hpack.cr
   ```

2. Run `shards install`

## Usage

```crystal
require "hpack"
```

There are two main classes provided by this shard, `HPack::Encoder` and `HPack::Decoder`. The default Encoder will be created with Indexing set to [`NONE`](https://httpwg.org/specs/rfc7541.html#literal.header.without.indexing), huffman encoding false, and the max table size set to 4k (4096 bytes). These parameters can all be set in the constructor.

```crystal
# To create a default Encoder:
default_encoder = HPack::Encoder.new

# To create an encoder with indexing set to Always and Huffman encoding set to true:
indexed_encoder = HPack::Encoder.new(
  indexing: HPack::Indexing::ALWAYS,
  huffman: true
)
positional_encoder = HPack::Encoder.new(HPack::Indexing::ALWAYS, true)

# To create an encoder with the max table size set to 8 KiB (8192 bytes):
large_table_encoder = HPack::Encoder.new(HPack::Indexing::ALWAYS, true, 8192)

# To encode headers into an owned Bytes value:
encoder = HPack::Encoder.new
headers = HTTP::Headers{
  ":status"       => "302",
  "cache-control" => "private",
  "date"          => "Mon, 21 Oct 2013 20:13:21 GMT",
  "location"      => "https://www.example.com",
}
bytes = encoder.encode(headers)

# To append an encoded block to a caller-owned buffer:
output = IO::Memory.new
encoder.encode_into(headers, output)

# To avoid HTTP::Headers adapter allocations, pass ordered name/value fields.
# Pseudo-headers must precede regular fields in this form.
fields = [
  {":status", "302"},
  {"cache-control", "private"},
]
bytes = encoder.encode(fields)
```

When a negotiated dynamic-table limit becomes effective, use
`Encoder#resize_table`. It resizes the local table immediately and prefixes
the next encoded field block with the required HPACK update. Multiple changes
between blocks are coalesced to the smallest and final sizes:

```crystal
encoder.resize_table(1024)
encoder.resize_table(2048)
bytes = encoder.encode(headers) # Begins with updates for 1024, then 2048.
```

Calling `encoder.table.resize` changes only local state and does not notify the
peer. The HTTP/2 implementation remains responsible for applying SETTINGS at
the correct acknowledgement boundary.

Use `HPack::HeaderField` when fields need different indexing or Huffman
behavior. Explicit field options override a policy block, which overrides the
per-call arguments and encoder defaults. `SMALLER` encodes each emitted name
and value with Huffman only when the result is strictly shorter:

```crystal
fields = [
  HPack::HeaderField.new(
    ":method",
    "GET",
    indexing: HPack::Indexing::INDEXED
  ),
  HPack::HeaderField.new(
    "authorization",
    "secret",
    indexing: HPack::Indexing::NEVER
  ),
  HPack::HeaderField.new("cache-control", "private"),
]
bytes = encoder.encode(fields, huffman: HPack::HuffmanMode::SMALLER)

# Policies receive normalized fields once, in final wire order.
bytes = encoder.encode(headers, huffman: HPack::HuffmanMode::SMALLER) do |name, _value|
  if name == "authorization"
    HPack::FieldOptions.new(indexing: HPack::Indexing::NEVER)
  end
end
```

To forward decoded fields without losing a never-indexed marker, retain the
decoder metadata and pass those fields directly to the outbound compression
context. Each HTTP/2 direction or connection must retain its own encoder and
decoder table:

```crystal
inbound_encoder = HPack::Encoder.new
inbound_decoder = HPack::Decoder.new
inbound_bytes = inbound_encoder.encode([
  HPack::HeaderField.new(":method", "GET"),
  HPack::HeaderField.new(
    "authorization",
    "secret",
    indexing: HPack::Indexing::NEVER
  ),
])
decoded = inbound_decoder.decode_with_metadata(inbound_bytes)

outbound_encoder = HPack::Encoder.new
forwarded = outbound_encoder.encode(
  decoded[:fields],
  huffman: HPack::HuffmanMode::SMALLER
)
```

To decode headers, use a `HPack::Decoder` instance. By default, a decoder is created with a 4k (4096 bytes) table size. That table size can be changed in the constructor.

```crystal
# To create a default Decoder:
decoder = HPack::Decoder.new

# To create a decoder with a larger table size:
decoder = HPack::Decoder.new(8192)

# To decode headers:
headers = decoder.decode(bytes)

# To decode headers into an existing `HTTP::Headers` instance:
headers = decoder.decode(bytes, HTTP::Headers.new)

# Apply a newly effective local protocol limit. If the peer's current table
# capacity is larger, its next field block must begin with a conforming update.
decoder.max_table_size = 1024
```

### Bounded decoding

`decode` and `decode_with_metadata` place no bound on decompressed output. For
untrusted network input, `decode_each` yields one ordered `DecodedHeader` at a
time and can enforce a decompressed field-section budget using the HTTP/2 size
rule (`name.bytesize + value.bytesize + 32` per field):

```crystal
result = decoder.decode_each(
  bytes,
  max_field_section_size: 64 * 1024,
) do |field|
  # Validate or retain this ordered field.
end

result.decoded_size   # Total size of the block, including suppressed fields.
result.limit_exceeded # True when the budget was crossed.
```

Crossing the budget never stops decompression: the crossing field and every
later field are counted but not yielded, while dynamic-table insertions and
size updates still apply, so the compression context stays synchronized with
the peer. A caller can reject the field section (for HTTP/2, typically a
stream-level refusal) and keep using the same decoder and connection.

To bound the allocation for any single literal, configure a hard cap in the
constructor. Exceeding it raises `HPack::ResourceLimitError` rather than
`HPack::Error`, because the input may be valid HPACK that this decoder refuses
to materialize. A hard-cap failure interrupts decompression, so that decoder's
compression context is stale and the decoder must be discarded:

```crystal
decoder = HPack::Decoder.new(max_decoded_string_size: 64 * 1024)
```

## Benchmarks

The benchmark entry point validates its fixtures before timing separate
Huffman, encoder, decoder, lookup, and policy reports. The default release-mode
suite is intended for routine local comparisons:

```sh
crystal run -p -s -t --release benchmark.cr
```

Use the extended mode for larger inputs, deeper tables, and eviction-heavy
sequences. Compile with `preview_mt` to include concurrent Huffman decoding:

```sh
HPACK_BENCH_EXTENDED=1 crystal run -p -s -t --release benchmark.cr
HPACK_BENCH_EXTENDED=1 crystal run -Dpreview_mt -p -s -t --release benchmark.cr
```

Results include throughput, time per operation, and allocated bytes per
operation. Compare runs built with the same Crystal version and machine; see
[the recorded baseline](benchmarks/BASELINE.md) for the current reference.

## Contributing

1. Fork it (<https://github.com/wyhaines/hpack/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Kirk Haines](https://github.com/wyhaines) - creator and maintainer

![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/wyhaines/hpack.cr?style=for-the-badge)
![GitHub issues](https://img.shields.io/github/issues/wyhaines/hpack.cr?style=for-the-badge)
