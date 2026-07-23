require "./fixtures"

module HPackBench
  POLICY_FIELDS = [
    HPack::HeaderField.new(
      ":status",
      "200",
      indexing: HPack::Indexing::INDEXED,
      huffman: HPack::HuffmanMode::SMALLER
    ),
    HPack::HeaderField.new(
      "cache-control",
      "private",
      indexing: HPack::Indexing::ALWAYS,
      huffman: HPack::HuffmanMode::SMALLER
    ),
    HPack::HeaderField.new(
      "date",
      "Mon, 21 Oct 2013 20:13:22 GMT",
      indexing: HPack::Indexing::NONE,
      huffman: HPack::HuffmanMode::SMALLER
    ),
    HPack::HeaderField.new(
      "authorization",
      "secret",
      indexing: HPack::Indexing::NEVER,
      huffman: HPack::HuffmanMode::SMALLER
    ),
    HPack::HeaderField.new(
      "set-cookie",
      Fixtures::HTTP_VALUE,
      indexing: HPack::Indexing::NONE,
      huffman: HPack::HuffmanMode::SMALLER
    ),
  ]

  ADAPTIVE_NAME_FIELDS = [
    HPack::HeaderField.new(
      "custom-key",
      "!",
      huffman: HPack::HuffmanMode::SMALLER
    ),
  ]

  ADAPTIVE_VALUE_FIELDS = [
    HPack::HeaderField.new(
      "!",
      "www.example.com",
      huffman: HPack::HuffmanMode::SMALLER
    ),
  ]

  def self.validate_policy
    validate_policy_wire_and_table
    validate_policy_size
    validate_adaptive_string_flags
    validate_policy_callback_allocations
  end

  def self.add_policy_reports(benchmark)
    fields = POLICY_FIELDS

    owned_encoder = HPack::Encoder.new
    owned_encoder.encode(fields)
    benchmark.report("value fields/adaptive/owned") do
      consume(owned_encoder.encode(fields))
    end

    caller_encoder = HPack::Encoder.new
    caller_encoder.encode(fields)
    writer = IO::Memory.new
    benchmark.report("value fields/adaptive/caller buffer") do
      writer.clear
      caller_encoder.encode_into(fields, writer)
      consume(writer.to_slice)
    end

    tuple_fields = Fixtures.response_fields
    tuple_encoder = HPack::Encoder.new
    tuple_writer = IO::Memory.new
    benchmark.report("callback value options/raw/caller buffer") do
      tuple_writer.clear
      tuple_encoder.encode_into(
        tuple_fields,
        tuple_writer,
        HPack::Indexing::NONE,
        HPack::HuffmanMode::NEVER
      ) do |name, _value|
        indexing = name == "set-cookie" ? HPack::Indexing::NEVER : nil
        HPack::FieldOptions.new(indexing: indexing)
      end
      consume(tuple_writer.to_slice)
    end

    adaptive_name_encoder = HPack::Encoder.new
    adaptive_name_writer = IO::Memory.new
    adaptive_name_encoder.encode_into(ADAPTIVE_NAME_FIELDS, adaptive_name_writer)
    benchmark.report("adaptive unknown/Huffman name/raw value/caller buffer") do
      adaptive_name_writer.clear
      adaptive_name_encoder.encode_into(ADAPTIVE_NAME_FIELDS, adaptive_name_writer)
      consume(adaptive_name_writer.to_slice)
    end

    adaptive_value_encoder = HPack::Encoder.new
    adaptive_value_writer = IO::Memory.new
    adaptive_value_encoder.encode_into(ADAPTIVE_VALUE_FIELDS, adaptive_value_writer)
    benchmark.report("adaptive unknown/raw name/Huffman value/caller buffer") do
      adaptive_value_writer.clear
      adaptive_value_encoder.encode_into(ADAPTIVE_VALUE_FIELDS, adaptive_value_writer)
      consume(adaptive_value_writer.to_slice)
    end
  end

  private def self.validate_policy_wire_and_table
    encoder = HPack::Encoder.new
    decoder = HPack::Decoder.new
    first = encoder.encode(POLICY_FIELDS)
    first_decoded = decoder.decode_with_metadata(first)
    second = encoder.encode(POLICY_FIELDS)
    second_decoded = decoder.decode_with_metadata(second)
    expected_fields = POLICY_FIELDS.map { |field| {field.name, field.value} }
    expected_indexing = [
      HPack::Indexing::INDEXED,
      HPack::Indexing::ALWAYS,
      HPack::Indexing::NONE,
      HPack::Indexing::NEVER,
      HPack::Indexing::NONE,
    ]

    assert(
      first_decoded[:fields].map { |field| {field.name, field.value} } == expected_fields,
      "policy first block fields"
    )
    assert(
      first_decoded[:fields].map(&.indexing) == expected_indexing,
      "policy first block metadata"
    )
    assert(
      second_decoded[:fields].map { |field| {field.name, field.value} } == expected_fields,
      "policy warmed block fields"
    )
    assert(encoder.table.to_a == [{"cache-control", "private"}], "policy table state")
  end

  private def self.validate_policy_size
    policy_encoder = HPack::Encoder.new
    policy_encoder.encode(POLICY_FIELDS)
    warmed_policy = policy_encoder.encode(POLICY_FIELDS)

    no_table_fields = POLICY_FIELDS.map do |field|
      HPack::HeaderField.new(
        field.name,
        field.value,
        indexing: HPack::Indexing::NONE,
        huffman: HPack::HuffmanMode::SMALLER
      )
    end
    no_table = HPack::Encoder.new.encode(no_table_fields)

    assert(warmed_policy.size < no_table.size, "selective policy encoded size")
    assert(policy_encoder.table.size == 1, "selective policy table entries")
  end

  private def self.validate_adaptive_string_flags
    name_writer = IO::Memory.new
    HPack::Encoder.new.encode_into(ADAPTIVE_NAME_FIELDS, name_writer)
    name_bytes = name_writer.to_slice
    assert(name_bytes[0] == HPack::Indexing::NONE.value, "adaptive name literal")
    assert(name_bytes[1].bit(7) == 1, "adaptive Huffman name flag")
    assert(name_bytes[10].bit(7) == 0, "adaptive raw value flag")
    assert(
      HPack::Decoder.new.decode(name_bytes) == HTTP::Headers{"custom-key" => "!"},
      "adaptive Huffman name round trip"
    )

    value_writer = IO::Memory.new
    HPack::Encoder.new.encode_into(ADAPTIVE_VALUE_FIELDS, value_writer)
    value_bytes = value_writer.to_slice
    assert(value_bytes[0] == HPack::Indexing::NONE.value, "adaptive value literal")
    assert(value_bytes[1].bit(7) == 0, "adaptive raw name flag")
    assert(value_bytes[3].bit(7) == 1, "adaptive Huffman value flag")
    assert(
      HPack::Decoder.new.decode(value_bytes) == HTTP::Headers{"!" => "www.example.com"},
      "adaptive Huffman value round trip"
    )
  end

  private def self.validate_policy_callback_allocations
    fields = Fixtures.response_fields
    encoder = HPack::Encoder.new
    writer = IO::Memory.new
    10.times do
      writer.clear
      encode_callback_policy(encoder, fields, writer)
    end

    allocated = Benchmark.memory do
      1_000.times do
        writer.clear
        encode_callback_policy(encoder, fields, writer)
      end
    end
    assert(allocated == 0, "value policy callback allocations")
  end

  private def self.encode_callback_policy(encoder, fields, writer)
    encoder.encode_into(
      fields,
      writer,
      HPack::Indexing::NONE,
      HPack::HuffmanMode::NEVER
    ) do |name, _value|
      indexing = name == "set-cookie" ? HPack::Indexing::NEVER : nil
      HPack::FieldOptions.new(indexing: indexing)
    end
  end
end
