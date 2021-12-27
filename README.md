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
encoder = HPack::Encoder.new

# To create an encoder with indexing set to Always and Huffamn encoding set to true:
encoder = HPack::Encoder.new(indexing: HPack::Indexing::ALWAYS, huffman: true)
encoder = HPack::Encoder.new(HPack::Indexing::ALWAYS, true)

# To create an encoder with the max table size set to 8k (8096 bytes):
encoder = HPack::Encoder.new(HPack::Indexing::ALWAYS, true, 8096)

# To encode headers:
encoder.encode(
  HTTP::Headers {
    ":status"       => "302",
    "cache-control" => "private",
    "date"          => "Mon, 21 Oct 2013 20:13:21 GMT",
    "location"      => "https://www.example.com"
  }
)
```

To decode headers, used a `HPack::Decoder` instance. By default, a decoder is created with a 4k (4096 bytes) table size. That table size can be changed in the constructor.

```crystal
# To create a default Decoder:
decoder = HPack::Decoder.new

# To create a decoder with a larger table size:
decoder = HPack::Decoder.new(8192)

# To decode headers:
headers = decoder.decode(bytes)

# To decode headers into an existing `HTTP::Headers` instance:
headers = decoder.decode(bytes, HTTP::Headers.new)
```

## Contributing

1. Fork it (<https://github.com/wyhaines/hpack/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Kirk Haines](https://github.com/wyhaines) - creator and maintainer

![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/wyhaines/hack.cr?style=for-the-badge)
![GitHub issues](https://img.shields.io/github/issues/wyhaines/hack.cr?style=for-the-badge)
