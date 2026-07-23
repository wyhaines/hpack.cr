require "benchmark"
require "http/headers"
require "../src/hpack"

module HPackBench
  extend self

  EXTENDED_FLAG = "HPACK_BENCH_EXTENDED"

  @@sink = 0_u64

  def extended?
    ENV[EXTENDED_FLAG]? == "1"
  end

  def mode
    extended? ? "extended" : "default"
  end

  def warmup_time
    extended? ? 750.milliseconds : 250.milliseconds
  end

  def calculation_time
    extended? ? 1500.milliseconds : 500.milliseconds
  end

  def report(title, &)
    puts
    puts "== #{title} =="
    Benchmark.ips(
      warmup: warmup_time,
      calculation: calculation_time,
      interactive: false
    ) do |benchmark|
      yield benchmark
    end
  end

  def assert(condition, message)
    raise "benchmark validation failed: #{message}" unless condition
  end

  @[NoInline]
  def consume(value : Int)
    @@sink = @@sink &* 33_u64 &+ value.to_u64
  end

  @[NoInline]
  def consume(value : Bytes)
    marker = value.size
    unless value.empty?
      marker &+= value[0].to_i
      marker &+= value[value.size - 1].to_i
    end
    consume(marker)
  end

  @[NoInline]
  def consume(value : String)
    marker = value.bytesize
    unless value.empty?
      marker &+= value.byte_at(0).to_i
      marker &+= value.byte_at(value.bytesize - 1).to_i
    end
    consume(marker)
  end

  @[NoInline]
  def consume(value : HTTP::Headers)
    consume(value.empty? ? 0 : 1)
  end

  def sink
    @@sink
  end
end
