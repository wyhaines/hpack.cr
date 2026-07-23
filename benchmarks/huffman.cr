require "./fixtures"

module HPackBench
  def self.validate_huffman
    Fixtures.extended_huffman.each do |fixture|
      encoded = HPack.huffman.encode(fixture.input)
      decoded = HPack.huffman.decode(encoded)
      assert(decoded == fixture.input, "Huffman round trip for #{fixture.label}")
    end

    encoded = HPack.huffman.encode("www.example.com")
    assert(encoded == Fixtures::RFC_HUFFMAN_WWW, "RFC Huffman fixture bytes")
    assert(
      HPack.huffman.encode(Fixtures::EXPANDING).size > Fixtures::EXPANDING.bytesize,
      "expanding Huffman fixture"
    )
  end

  def self.add_huffman_reports(benchmark, extended)
    fixtures = extended ? Fixtures.extended_huffman : Fixtures.default_huffman
    fixtures.each do |fixture|
      add_huffman_encode_report(benchmark, fixture)
      add_huffman_decode_report(benchmark, fixture)
    end

    {% if flag?(:preview_mt) %}
      add_huffman_contention_report(benchmark) if extended
    {% end %}
  end

  private def self.add_huffman_encode_report(benchmark, fixture)
    input = fixture.input
    benchmark.report("huffman/encode/#{fixture.label}") do
      consume(HPack.huffman.encode(input))
    end
  end

  private def self.add_huffman_decode_report(benchmark, fixture)
    encoded = HPack.huffman.encode(fixture.input)
    benchmark.report("huffman/decode/#{fixture.label}") do
      consume(HPack.huffman.decode(encoded))
    end
  end

  {% if flag?(:preview_mt) %}
    private def self.add_huffman_contention_report(benchmark)
      encoded = HPack.huffman.encode(Fixtures::HTTP_VALUE)
      completed = Channel(Int32).new(4)

      benchmark.report("huffman/decode/4-fiber contention") do
        4.times do
          spawn do
            completed.send(HPack.huffman.decode(encoded).bytesize)
          end
        end

        total = 0
        4.times { total += completed.receive }
        consume(total)
      end
    end
  {% end %}
end
