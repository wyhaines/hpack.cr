require "./huffman"
require "./encoder"
require "./decoder"
require "./lookup"
require "./policy"

module HPackBench
  def self.run
    puts "HPACK benchmark suite"
    puts "Crystal: #{Crystal::VERSION}"
    puts "Mode: #{mode}"
    {% if flag?(:preview_mt) %}
      puts "preview_mt: true"
    {% else %}
      puts "preview_mt: false"
    {% end %}
    puts "Timing: #{warmup_time.total_milliseconds.to_i} ms warmup, " \
         "#{calculation_time.total_milliseconds.to_i} ms calculation per case"

    validate_huffman
    validate_encoder
    validate_decoder
    validate_lookup
    validate_policy
    puts "Untimed fixture validation passed."

    report("Huffman") { |benchmark| add_huffman_reports(benchmark, extended?) }
    report("Encoder") { |benchmark| add_encoder_reports(benchmark, extended?) }
    report("Decoder") { |benchmark| add_decoder_reports(benchmark, extended?) }
    report("Lookup") { |benchmark| add_lookup_reports(benchmark, extended?) }
    report("Policy") { |benchmark| add_policy_reports(benchmark) }

    puts
    puts "Benchmark sink: #{sink}"
  end
end
