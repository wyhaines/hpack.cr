require "./fixtures"

class HPack::Encoder
  # :nodoc:
  def benchmark_lookup(name, value)
    indexed(name, value)
  end
end

module HPackBench
  def self.validate_lookup
    encoder = depth_encoder(17)
    assert_lookup(
      encoder,
      "x-depth-16",
      "value-16",
      HPack::STATIC_TABLE_SIZE + 1,
      "newest dynamic lookup"
    )
    assert_lookup(
      encoder,
      "x-depth-8",
      "value-8",
      HPack::STATIC_TABLE_SIZE + 9,
      "middle dynamic lookup"
    )
    assert_lookup(
      encoder,
      "x-depth-0",
      "value-0",
      HPack::STATIC_TABLE_SIZE + 17,
      "oldest dynamic lookup"
    )

    static = HPack::Encoder.new.benchmark_lookup(":method", "GET")
    assert(static == {2, "GET"}, "static lookup")
    assert(encoder.benchmark_lookup("x-missing", "value").nil?, "unknown-name miss")

    repeated = repeated_name_encoder(17)
    assert(
      repeated.benchmark_lookup("x-repeated", "new-value") == {
        HPack::STATIC_TABLE_SIZE + 1,
        nil,
      },
      "repeated custom name lookup"
    )

    small = small_table_encoder
    assert(small.table.bytesize <= 128, "small lookup table limit")
    assert(small.table.size == 2, "small lookup table retained count")
    newest_name, newest_value = small.table.first
    assert_lookup(
      small,
      newest_name,
      newest_value,
      HPack::STATIC_TABLE_SIZE + 1,
      "small-table newest lookup"
    )
    oldest_name, oldest_value = small.table.last
    assert_lookup(
      small,
      oldest_name,
      oldest_value,
      HPack::STATIC_TABLE_SIZE + small.table.size,
      "small-table oldest lookup"
    )

    validate_static_encoder
    validate_repeated_name_encoder
  end

  def self.add_lookup_reports(benchmark, extended)
    add_lookup_report(
      benchmark,
      "lookup/static exact/early pseudo",
      HPack::Encoder.new,
      ":method",
      "GET"
    )
    add_lookup_report(
      benchmark,
      "lookup/static exact/late",
      HPack::Encoder.new,
      "www-authenticate",
      ""
    )
    add_lookup_report(
      benchmark,
      "lookup/static name-only/late",
      HPack::Encoder.new,
      "www-authenticate",
      "challenge"
    )

    add_depth_lookup_reports(benchmark, 17, 4096, "default table")
    add_lookup_report(
      benchmark,
      "lookup/default table/unknown-name miss",
      depth_encoder(17),
      "x-missing",
      "value"
    )
    add_lookup_report(
      benchmark,
      "lookup/default table/repeated-name dynamic-name hit",
      repeated_name_encoder(17),
      "x-repeated",
      "new-value"
    )

    small = small_table_encoder
    name, value = small.table.last
    add_lookup_report(
      benchmark,
      "lookup/small table/oldest retained",
      small,
      name,
      value
    )

    add_static_encoder_reports(benchmark)
    add_repeated_name_encoder_report(benchmark)
    add_depth_lookup_reports(benchmark, 128, 8192, "large table") if extended
  end

  private def self.validate_static_encoder
    encoder = HPack::Encoder.new
    writer = IO::Memory.new
    pseudo_fields = [
      {":method", "GET"},
      {":scheme", "http"},
      {":path", "/"},
    ]
    encoder.encode_into(pseudo_fields, writer)
    assert(writer.to_slice == Fixtures::STATIC_REQUEST, "static pseudo-header block")

    writer.clear
    encoder.encode_into([{"www-authenticate", ""}], writer)
    assert(writer.to_slice == Bytes[0xbd], "late static exact block")
    assert(
      HPack::Decoder.new.decode(writer.to_slice) == HTTP::Headers{"www-authenticate" => ""},
      "late static exact round trip"
    )

    writer.clear
    encoder.encode_into([{"www-authenticate", "challenge"}], writer)
    expected = Bytes[
      0x0f, 0x2e, 0x09, 0x63, 0x68, 0x61,
      0x6c, 0x6c, 0x65, 0x6e, 0x67, 0x65,
    ]
    assert(writer.to_slice == expected, "late static name-only block")
    assert(
      HPack::Decoder.new.decode(writer.to_slice) == HTTP::Headers{
        "www-authenticate" => "challenge",
      },
      "late static name-only round trip"
    )
  end

  private def self.validate_repeated_name_encoder
    encoder = repeated_name_encoder(17)
    encoded = encoder.encode([{"x-repeated", "new-value"}])
    assert(encoded.size == 12, "dynamic name reuse wire size")

    decoder = HPack::Decoder.new
    17.times do |index|
      decoder.table.add("x-repeated", "value-#{index}")
    end
    assert(
      decoder.decode(encoded) == HTTP::Headers{"x-repeated" => "new-value"},
      "dynamic name reuse round trip"
    )
  end

  private def self.add_static_encoder_reports(benchmark)
    add_static_encoder_report(
      benchmark,
      "lookup/end-to-end/static pseudo block",
      [
        {":method", "GET"},
        {":scheme", "http"},
        {":path", "/"},
      ]
    )
    add_static_encoder_report(
      benchmark,
      "lookup/end-to-end/static late exact",
      [{"www-authenticate", ""}]
    )
    add_static_encoder_report(
      benchmark,
      "lookup/end-to-end/static late name-only",
      [{"www-authenticate", "challenge"}]
    )
  end

  private def self.add_static_encoder_report(benchmark, label, fields)
    encoder = HPack::Encoder.new
    writer = IO::Memory.new

    benchmark.report(label) do
      writer.clear
      encoder.encode_into(fields, writer)
      consume(writer.to_slice)
    end
  end

  private def self.add_repeated_name_encoder_report(benchmark)
    fields = [{"x-repeated", "new-value"}]
    encoder = repeated_name_encoder(17)
    writer = IO::Memory.new

    benchmark.report("lookup/end-to-end/repeated dynamic name") do
      writer.clear
      encoder.encode_into(fields, writer)
      consume(writer.to_slice)
    end
  end

  private def self.add_depth_lookup_reports(benchmark, count, maximum, label)
    add_lookup_report(
      benchmark,
      "lookup/#{label}/dynamic newest",
      depth_encoder(count, maximum),
      "x-depth-#{count - 1}",
      "value-#{count - 1}"
    )

    middle = count // 2
    add_lookup_report(
      benchmark,
      "lookup/#{label}/dynamic middle",
      depth_encoder(count, maximum),
      "x-depth-#{middle}",
      "value-#{middle}"
    )

    add_lookup_report(
      benchmark,
      "lookup/#{label}/dynamic oldest",
      depth_encoder(count, maximum),
      "x-depth-0",
      "value-0"
    )
  end

  private def self.add_lookup_report(benchmark, label, encoder, name, value)
    benchmark.report(label) do
      if result = encoder.benchmark_lookup(name, value)
        consume(result[0])
      else
        consume(0)
      end
    end
  end

  private def self.assert_lookup(encoder, name, value, expected_index, message)
    result = encoder.benchmark_lookup(name, value)
    assert(result == {expected_index, value}, message)
  end

  private def self.depth_encoder(count, maximum = 4096)
    encoder = HPack::Encoder.new(max_table_size: maximum)
    count.times do |index|
      encoder.table.add("x-depth-#{index}", "value-#{index}")
    end
    encoder
  end

  private def self.repeated_name_encoder(count)
    encoder = HPack::Encoder.new
    count.times do |index|
      encoder.table.add("x-repeated", "value-#{index}")
    end
    encoder
  end

  private def self.small_table_encoder
    encoder = HPack::Encoder.new(max_table_size: 128)
    12.times do |index|
      encoder.table.add("x-small-#{index}", "value-#{index}")
    end
    encoder
  end
end
