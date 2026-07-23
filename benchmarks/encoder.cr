require "./fixtures"

module HPackBench
  def self.validate_encoder
    headers = Fixtures.literal_headers

    [HPack::Indexing::NONE, HPack::Indexing::ALWAYS, HPack::Indexing::NEVER].each do |indexing|
      [false, true].each do |huffman|
        encoder = HPack::Encoder.new(indexing: indexing, huffman: huffman)
        encoded = encoder.encode(headers)
        decoder = HPack::Decoder.new

        if indexing == HPack::Indexing::NEVER
          decoded = decoder.decode_with_metadata(encoded)
          assert(decoded[:headers] == headers, "never-indexed encoder round trip")
          assert(
            decoded[:fields].all?(&.indexing.==(HPack::Indexing::NEVER)),
            "never-indexed encoder metadata"
          )
        else
          assert(decoder.decode(encoded) == headers, "encoder round trip")
        end

        expected_table_size = indexing == HPack::Indexing::ALWAYS ? 1 : 0
        assert(encoder.table.size == expected_table_size, "encoder table state")
      end
    end

    validate_encoder_names
    validate_multiple_values
    validate_encoder_output_ownership
    validate_warmed_encoder
    validate_eviction_encoder
  end

  def self.add_encoder_reports(benchmark, extended)
    headers = Fixtures.literal_headers
    add_cold_encoder_report(benchmark, "NONE/raw", headers, HPack::Indexing::NONE, false)
    add_cold_encoder_report(benchmark, "NONE/Huffman", headers, HPack::Indexing::NONE, true)
    add_cold_encoder_report(benchmark, "ALWAYS/raw", headers, HPack::Indexing::ALWAYS, false)
    add_cold_encoder_report(benchmark, "ALWAYS/Huffman", headers, HPack::Indexing::ALWAYS, true)
    add_cold_encoder_report(benchmark, "NEVER/raw", headers, HPack::Indexing::NEVER, false)
    add_cold_encoder_report(benchmark, "NEVER/Huffman", headers, HPack::Indexing::NEVER, true)

    add_encoder_name_reports(benchmark)
    add_multiple_value_report(benchmark)
    add_owned_output_report(benchmark)
    add_caller_output_report(benchmark)
    add_field_output_reports(benchmark)
    add_warmed_dynamic_report(benchmark)
    add_eviction_encoder_report(benchmark) if extended
  end

  private def self.validate_encoder_names
    lowercase = Fixtures.literal_headers("x-benchmark", "value")
    mixed_case = Fixtures.literal_headers("X-Benchmark", "value")
    lowercase_bytes = HPack::Encoder.new.encode(lowercase)
    mixed_case_bytes = HPack::Encoder.new.encode(mixed_case)
    assert(lowercase_bytes == mixed_case_bytes, "lowercase and mixed-case header names")
  end

  private def self.validate_multiple_values
    headers = Fixtures.multiple_value_headers
    encoded = HPack::Encoder.new.encode(headers)
    assert(HPack::Decoder.new.decode(encoded) == headers, "multiple header values")
  end

  private def self.validate_encoder_output_ownership
    headers = Fixtures.literal_headers
    encoder = HPack::Encoder.new
    first = encoder.encode(headers)
    expected = first.dup
    encoder.encode(Fixtures.literal_headers("x-other", "other"))
    assert(first == expected, "owned encoder output")

    writer = IO::Memory.new
    encoder.encode_into(headers, writer)
    assert(writer.to_slice == expected, "caller-owned encoder output")

    fields = Fixtures.response_fields
    headers = Fixtures.response_headers
    assert(
      HPack::Encoder.new.encode(fields) == HPack::Encoder.new.encode(headers),
      "ordered field encoder output"
    )
  end

  private def self.validate_warmed_encoder
    headers = Fixtures.response_headers
    encoder = HPack::Encoder.new(indexing: HPack::Indexing::ALWAYS, huffman: true)
    first = encoder.encode(headers)
    second = encoder.encode(headers)
    decoder = HPack::Decoder.new

    assert(decoder.decode(first) == headers, "primed encoder first block")
    assert(decoder.decode(second) == headers, "primed encoder indexed block")
  end

  private def self.validate_eviction_encoder
    encoder = HPack::Encoder.new(
      indexing: HPack::Indexing::ALWAYS,
      max_table_size: 96
    )
    decoder = HPack::Decoder.new(96)

    eviction_headers.each do |headers|
      assert(decoder.decode(encoder.encode(headers)) == headers, "eviction sequence")
      assert(encoder.table.bytesize <= 96, "small encoder table limit")
      assert(decoder.table.bytesize <= 96, "small decoder table limit")
    end
  end

  private def self.add_cold_encoder_report(benchmark, label, headers, indexing, huffman)
    benchmark.report("encoder/cold literal/#{label}/owned") do
      encoder = HPack::Encoder.new(indexing: indexing, huffman: huffman)
      consume(encoder.encode(headers))
    end
  end

  private def self.add_encoder_name_reports(benchmark)
    lowercase_headers = Fixtures.literal_headers("x-benchmark", "value")
    lowercase_encoder = HPack::Encoder.new
    benchmark.report("encoder/warm raw/lowercase name") do
      consume(lowercase_encoder.encode(lowercase_headers))
    end

    mixed_case_headers = Fixtures.literal_headers("X-Benchmark", "value")
    mixed_case_encoder = HPack::Encoder.new
    benchmark.report("encoder/warm raw/mixed-case name") do
      consume(mixed_case_encoder.encode(mixed_case_headers))
    end
  end

  private def self.add_multiple_value_report(benchmark)
    headers = Fixtures.multiple_value_headers
    encoder = HPack::Encoder.new
    benchmark.report("encoder/warm raw/multiple values") do
      consume(encoder.encode(headers))
    end
  end

  private def self.add_owned_output_report(benchmark)
    headers = Fixtures.response_headers
    encoder = HPack::Encoder.new
    benchmark.report("encoder/warm raw/owned output") do
      consume(encoder.encode(headers))
    end
  end

  private def self.add_caller_output_report(benchmark)
    headers = Fixtures.response_headers
    encoder = HPack::Encoder.new
    writer = IO::Memory.new
    benchmark.report("encoder/warm raw/caller buffer reset") do
      writer.clear
      encoder.encode_into(headers, writer)
      consume(writer.to_slice)
    end
  end

  private def self.add_field_output_reports(benchmark)
    fields = Fixtures.response_fields
    owned_encoder = HPack::Encoder.new
    benchmark.report("encoder/warm fields/raw/owned output") do
      consume(owned_encoder.encode(fields))
    end

    caller_encoder = HPack::Encoder.new
    writer = IO::Memory.new
    benchmark.report("encoder/warm fields/raw/caller buffer reset") do
      writer.clear
      caller_encoder.encode_into(fields, writer)
      consume(writer.to_slice)
    end
  end

  private def self.add_warmed_dynamic_report(benchmark)
    headers = Fixtures.response_headers
    encoder = HPack::Encoder.new(indexing: HPack::Indexing::ALWAYS, huffman: true)
    encoder.encode(headers)

    benchmark.report("encoder/warm exact dynamic/Huffman") do
      consume(encoder.encode(headers))
    end
  end

  private def self.add_eviction_encoder_report(benchmark)
    headers = eviction_headers
    encoder = HPack::Encoder.new(
      indexing: HPack::Indexing::ALWAYS,
      max_table_size: 96
    )
    headers.each { |item| encoder.encode(item) }
    index = 0

    benchmark.report("encoder/warm mutating/small-table eviction") do
      consume(encoder.encode(headers[index]))
      index = (index + 1) % headers.size
    end
  end

  private def self.eviction_headers
    Array.new(8) do |index|
      Fixtures.literal_headers("x-eviction", "value-#{index}")
    end
  end
end
