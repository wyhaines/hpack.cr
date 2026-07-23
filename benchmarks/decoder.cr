require "./fixtures"

module HPackBench
  record DecoderFixture, bytes : Bytes, headers : HTTP::Headers

  def self.validate_decoder
    assert(
      HPack::Decoder.new.decode(Fixtures::STATIC_REQUEST) == Fixtures.static_request_headers,
      "static-only decoder fixture"
    )
    assert(
      HPack::Decoder.new.decode(Fixtures::RAW_LITERAL) ==
      HTTP::Headers{":path" => "/sample/path"},
      "raw literal decoder fixture"
    )

    huffman_headers = Fixtures.literal_headers
    assert(
      HPack::Decoder.new.decode(huffman_literal_block) == huffman_headers,
      "Huffman literal decoder fixture"
    )

    validate_rfc_dynamic_sequence
    validate_table_size_update
    validate_decoder_metadata
    validate_caller_headers
    validate_decoder_sequence(encoded_sequence(8, 96), 96, "small-table eviction")
    validate_decoder_sequence(encoded_sequence(128, 8192), 8192, "large-table sequence")
  end

  def self.add_decoder_reports(benchmark, extended)
    static_decoder = HPack::Decoder.new
    benchmark.report("decoder/warm/static-only") do
      consume(static_decoder.decode(Fixtures::STATIC_REQUEST))
    end

    literal_decoder = HPack::Decoder.new
    benchmark.report("decoder/warm/literal raw") do
      consume(literal_decoder.decode(Fixtures::RAW_LITERAL))
    end

    huffman_block = huffman_literal_block
    huffman_decoder = HPack::Decoder.new
    benchmark.report("decoder/warm/literal Huffman") do
      consume(huffman_decoder.decode(huffman_block))
    end

    dynamic_decoder = HPack::Decoder.new
    benchmark.report("decoder/reset/RFC dynamic sequence") do
      dynamic_decoder.table.clear
      consume(dynamic_decoder.decode(Fixtures::RFC_REQUEST_1))
      consume(dynamic_decoder.decode(Fixtures::RFC_REQUEST_2))
      consume(dynamic_decoder.decode(Fixtures::RFC_REQUEST_3))
    end

    benchmark.report("decoder/cold/table-size update") do
      decoder = HPack::Decoder.new
      consume(decoder.decode(Fixtures::TABLE_SIZE_UPDATE))
    end

    metadata_decoder = HPack::Decoder.new
    benchmark.report("decoder/warm/metadata") do
      decoded = metadata_decoder.decode_with_metadata(Fixtures::NEVER_INDEXED)
      consume(decoded[:headers])
      consume(decoded[:fields].size)
    end

    caller_decoder = HPack::Decoder.new
    benchmark.report("decoder/warm/static/caller headers construct") do
      headers = HTTP::Headers.new
      consume(caller_decoder.decode(Fixtures::STATIC_REQUEST, headers))
    end

    add_decoder_sequence_report(
      benchmark,
      "decoder/cold/small-table eviction sequence",
      encoded_sequence(8, 96),
      96
    )

    if extended
      add_decoder_sequence_report(
        benchmark,
        "decoder/cold/large-table sequence",
        encoded_sequence(128, 8192),
        8192
      )
    end
  end

  private def self.validate_rfc_dynamic_sequence
    decoder = HPack::Decoder.new
    assert(
      decoder.decode(Fixtures::RFC_REQUEST_1) == Fixtures.rfc_request_1_headers,
      "first RFC dynamic request"
    )
    assert(
      decoder.decode(Fixtures::RFC_REQUEST_2) == Fixtures.rfc_request_2_headers,
      "second RFC dynamic request"
    )
    assert(
      decoder.decode(Fixtures::RFC_REQUEST_3) == Fixtures.rfc_request_3_headers,
      "third RFC dynamic request"
    )
  end

  private def self.validate_table_size_update
    decoder = HPack::Decoder.new
    decoded = decoder.decode(Fixtures::TABLE_SIZE_UPDATE)
    assert(decoded == HTTP::Headers{":method" => "GET"}, "table-size update output")
    assert(decoder.table.maximum == 0, "table-size update state")
  end

  private def self.validate_decoder_metadata
    decoded = HPack::Decoder.new.decode_with_metadata(Fixtures::NEVER_INDEXED)
    expected = HTTP::Headers{
      ":method"       => "GET",
      "authorization" => "secret",
    }
    assert(decoded[:headers] == expected, "decoder metadata output")
    assert(
      decoded[:fields].last.indexing == HPack::Indexing::NEVER,
      "decoder never-indexed metadata"
    )
  end

  private def self.validate_caller_headers
    headers = HTTP::Headers{"x-existing" => "value"}
    decoded = HPack::Decoder.new.decode(Fixtures::STATIC_REQUEST, headers)
    assert(decoded.same?(headers), "caller-supplied headers identity")
    assert(decoded["x-existing"] == "value", "caller-supplied headers contents")
    assert(decoded[":method"] == "GET", "caller-supplied decoded contents")
  end

  private def self.validate_decoder_sequence(fixtures, maximum, label)
    decoder = HPack::Decoder.new(maximum)
    fixtures.each do |fixture|
      assert(decoder.decode(fixture.bytes) == fixture.headers, label)
      assert(decoder.table.bytesize <= maximum, "#{label} table limit")
    end
  end

  private def self.add_decoder_sequence_report(benchmark, label, fixtures, maximum)
    benchmark.report(label) do
      decoder = HPack::Decoder.new(maximum)
      fixtures.each { |fixture| consume(decoder.decode(fixture.bytes)) }
    end
  end

  private def self.huffman_literal_block
    encoder = HPack::Encoder.new(huffman: true)
    encoder.encode(Fixtures.literal_headers)
  end

  private def self.encoded_sequence(count, maximum)
    encoder = HPack::Encoder.new(
      indexing: HPack::Indexing::ALWAYS,
      max_table_size: maximum
    )

    Array.new(count) do |index|
      headers = Fixtures.literal_headers("x-sequence", "value-#{index}")
      DecoderFixture.new(encoder.encode(headers), headers)
    end
  end
end
