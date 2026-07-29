require "./spec_helper"

private class CallbackBoom < Exception
end

# RFC 7541 appendix C.4.1: :method GET, :scheme http, :path /, and a
# Huffman-coded :authority www.example.com with incremental indexing.
private RFC_HUFFMAN_REQUEST = Bytes[
  0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2,
  0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4,
  0xff,
]

# One field of every representation kind, with dynamic and static duplicates:
# GET, +("a","A"), never ("b","B"), plain ("c","C"), dynamic ("a","A"), GET.
private MIXED_REPRESENTATIONS = Bytes[
  0x82,
  0x40, 0x01, 0x61, 0x01, 0x41,
  0x10, 0x01, 0x62, 0x01, 0x42,
  0x00, 0x01, 0x63, 0x01, 0x43,
  0xbe,
  0x82,
]

# ("a","A") without indexing: field-section size 1 + 1 + 32 = 34.
private SINGLE_LITERAL = Bytes[0x00, 0x01, 0x61, 0x01, 0x41]

# ("a","A") then ("b","B"), 34 bytes of field-section size each.
private TWO_LITERALS = Bytes[
  0x00, 0x01, 0x61, 0x01, 0x41,
  0x00, 0x01, 0x62, 0x01, 0x42,
]

# ("a","A") without indexing, then ("k","v") with incremental indexing.
private LITERAL_THEN_INSERTION = Bytes[
  0x00, 0x01, 0x61, 0x01, 0x41,
  0x40, 0x01, 0x6b, 0x01, 0x76,
]

describe "HPack::Decoder#decode_each" do
  it "yields every representation kind in wire order with indexing markers" do
    decoder = HPack::Decoder.new
    seen = [] of {String, String, HPack::Indexing}

    result = decoder.decode_each(MIXED_REPRESENTATIONS) do |field|
      seen << {field.name, field.value, field.indexing}
    end

    seen.should eq [
      {":method", "GET", HPack::Indexing::INDEXED},
      {"a", "A", HPack::Indexing::ALWAYS},
      {"b", "B", HPack::Indexing::NEVER},
      {"c", "C", HPack::Indexing::NONE},
      {"a", "A", HPack::Indexing::INDEXED},
      {":method", "GET", HPack::Indexing::INDEXED},
    ]
    result.decoded_size.should eq 220_u64
    result.limit_exceeded.should be_false
  end

  it "decodes an empty block without invoking the callback" do
    calls = 0

    result = HPack::Decoder.new.decode_each(Bytes.empty) { calls += 1 }

    calls.should eq 0
    result.should eq HPack::DecodeResult.new(
      decoded_size: 0_u64,
      limit_exceeded: false
    )
  end

  it "produces the same fields as decode and decode_with_metadata" do
    plain = HPack::Decoder.new.decode(RFC_HUFFMAN_REQUEST)
    with_metadata = HPack::Decoder.new.decode_with_metadata(RFC_HUFFMAN_REQUEST)
    streamed = [] of HPack::DecodedHeader
    result = HPack::Decoder.new.decode_each(RFC_HUFFMAN_REQUEST) do |field|
      streamed << field
    end

    with_metadata[:headers].should eq plain
    streamed.should eq with_metadata[:fields]
    result.decoded_size.should eq 180_u64
    result.limit_exceeded.should be_false
  end

  describe "field-section limits" do
    it "accepts a total exactly equal to the limit" do
      yielded = [] of String

      result = HPack::Decoder.new.decode_each(
        SINGLE_LITERAL,
        max_field_section_size: 34,
      ) { |field| yielded << field.name }

      yielded.should eq ["a"]
      result.decoded_size.should eq 34_u64
      result.limit_exceeded.should be_false
    end

    it "does not yield the crossing field but still counts it" do
      yielded = [] of String

      result = HPack::Decoder.new.decode_each(
        SINGLE_LITERAL,
        max_field_section_size: 33,
      ) { |field| yielded << field.name }

      yielded.should be_empty
      result.decoded_size.should eq 34_u64
      result.limit_exceeded.should be_true
    end

    it "yields nothing after the limit while counting every later field" do
      yielded = [] of String

      result = HPack::Decoder.new.decode_each(
        TWO_LITERALS,
        max_field_section_size: 34,
      ) { |field| yielded << field.name }

      yielded.should eq ["a"]
      result.decoded_size.should eq 68_u64
      result.limit_exceeded.should be_true
    end

    it "counts duplicate indexed fields toward the total" do
      yielded = [] of String

      result = HPack::Decoder.new.decode_each(
        Bytes[0x82, 0x82],
        max_field_section_size: 42,
      ) { |field| yielded << field.name }

      yielded.should eq [":method"]
      result.decoded_size.should eq 84_u64
      result.limit_exceeded.should be_true
    end

    it "counts decoded Huffman output rather than encoded bytes" do
      result = HPack::Decoder.new.decode_each(
        RFC_HUFFMAN_REQUEST,
        max_field_section_size: 179,
      ) { }

      result.decoded_size.should eq 180_u64
      result.limit_exceeded.should be_true
    end

    it "applies suppressed dynamic insertions for later blocks" do
      decoder = HPack::Decoder.new

      result = decoder.decode_each(
        LITERAL_THEN_INSERTION,
        max_field_section_size: 0,
      ) { |field| raise "unexpected yield of #{field.name}" }

      result.decoded_size.should eq 68_u64
      result.limit_exceeded.should be_true
      decoder.table[0]?.should eq({"k", "v"})

      names = [] of String
      decoder.decode_each(Bytes[0xbe]) { |field| names << field.name }
      names.should eq ["k"]
    end

    it "inserts the field that crosses the limit itself" do
      decoder = HPack::Decoder.new

      result = decoder.decode_each(
        Bytes[0x40, 0x01, 0x6b, 0x01, 0x76],
        max_field_section_size: 0,
      ) { }

      result.limit_exceeded.should be_true
      decoder.table[0]?.should eq({"k", "v"})
      decoder.decode(Bytes[0xbe]).should eq HTTP::Headers{"k" => "v"}
    end

    it "excludes table size updates from the decoded size" do
      decoder = HPack::Decoder.new

      result = decoder.decode_each(
        Bytes[0x20, 0x82],
        max_field_section_size: 42,
      ) { }

      decoder.table.maximum.should eq 0
      result.decoded_size.should eq 42_u64
      result.limit_exceeded.should be_false
    end

    it "treats malformed bytes after an over-limit field as compression errors" do
      decoder = HPack::Decoder.new

      expect_raises(HPack::Error, "invalid index: 0") do
        decoder.decode_each(
          Bytes[0x00, 0x01, 0x61, 0x01, 0x41, 0x80],
          max_field_section_size: 0,
        ) { }
      end
    end

    it "rejects invalid limits before any table mutation" do
      decoder = HPack::Decoder.new

      expect_raises(ArgumentError, /field-section size limit/) do
        decoder.decode_each(
          LITERAL_THEN_INSERTION,
          max_field_section_size: -1,
        ) { }
      end
      expect_raises(ArgumentError, /field-section size limit/) do
        decoder.decode_each(
          LITERAL_THEN_INSERTION,
          max_field_section_size: Int128::MAX,
        ) { }
      end

      decoder.table.size.should eq 0
    end
  end

  describe "callback exceptions" do
    it "saves the first exception, drains the block, and re-raises it" do
      decoder = HPack::Decoder.new
      boom = CallbackBoom.new("boom")
      calls = 0

      raised = expect_raises(CallbackBoom, "boom") do
        decoder.decode_each(Bytes[0x82, 0x40, 0x01, 0x6b, 0x01, 0x76]) do
          calls += 1
          raise boom
        end
      end

      raised.should be(boom)
      calls.should eq 1
      decoder.table[0]?.should eq({"k", "v"})
      decoder.decode(Bytes[0xbe]).should eq HTTP::Headers{"k" => "v"}
    end

    it "reports a malformed remainder instead of the callback exception" do
      decoder = HPack::Decoder.new

      expect_raises(HPack::Error, "invalid index: 0") do
        decoder.decode_each(Bytes[0x82, 0x80]) do
          raise CallbackBoom.new("boom")
        end
      end
    end

    it "drains adapter decodes when the headers object rejects a value" do
      decoder = HPack::Decoder.new
      bytes = Bytes[
        0x00, 0x01, 0x78, 0x03, 0x61, 0x00, 0x62,
        0x40, 0x01, 0x6b, 0x01, 0x76,
      ]

      expect_raises(ArgumentError) do
        decoder.decode(bytes)
      end

      decoder.table[0]?.should eq({"k", "v"})
      decoder.decode(Bytes[0xbe]).should eq HTTP::Headers{"k" => "v"}
    end
  end
end

describe "HPack::Decoder decoded-string caps" do
  it "rejects invalid caps in the constructor" do
    expect_raises(ArgumentError, /decoded string size cap/) do
      HPack::Decoder.new(max_decoded_string_size: -1)
    end
    expect_raises(ArgumentError, /decoded string size cap/) do
      HPack::Decoder.new(max_decoded_string_size: Int64::MAX)
    end
  end

  it "exposes the configured cap and defaults to unlimited" do
    HPack::Decoder.new.max_decoded_string_size.should be_nil
    HPack::Decoder.new(max_decoded_string_size: 16)
      .max_decoded_string_size.should eq 16
  end

  it "bounds raw literal values at the configured cap" do
    at_cap = Bytes[0x00, 0x01, 0x78, 0x04, 0x61, 0x62, 0x63, 0x64]
    over_cap = Bytes[0x00, 0x01, 0x78, 0x05, 0x61, 0x62, 0x63, 0x64, 0x65]

    decoder = HPack::Decoder.new(max_decoded_string_size: 4)
    decoder.decode(at_cap).should eq HTTP::Headers{"x" => "abcd"}

    expect_raises(HPack::ResourceLimitError, /configured cap/) do
      HPack::Decoder.new(max_decoded_string_size: 4).decode(over_cap)
    end
  end

  it "bounds raw literal names at the configured cap" do
    over_cap = Bytes[0x00, 0x05, 0x61, 0x62, 0x63, 0x64, 0x65, 0x01, 0x76]

    expect_raises(HPack::ResourceLimitError, /configured cap/) do
      HPack::Decoder.new(max_decoded_string_size: 4).decode(over_cap)
    end
  end

  it "bounds Huffman output as decoded bytes rather than encoded bytes" do
    HPack::Decoder.new(max_decoded_string_size: 15)
      .decode(RFC_HUFFMAN_REQUEST)[":authority"].should eq "www.example.com"

    expect_raises(HPack::ResourceLimitError, /configured cap/) do
      HPack::Decoder.new(max_decoded_string_size: 14)
        .decode(RFC_HUFFMAN_REQUEST)
    end
  end

  it "accepts empty literals under a zero cap and rejects the first byte" do
    decoder = HPack::Decoder.new(max_decoded_string_size: 0)

    empty_values = [] of String
    decoder.decode_each(Bytes[0x02, 0x00]) { |field| empty_values << field.value }
    empty_values.should eq [""]

    empty_values.clear
    decoder.decode_each(Bytes[0x02, 0x80]) { |field| empty_values << field.value }
    empty_values.should eq [""]

    expect_raises(HPack::ResourceLimitError, /configured cap/) do
      decoder.decode_each(Bytes[0x02, 0x01, 0x61]) { }
    end
  end

  it "keeps a truncated declared length a compression error, not a cap error" do
    truncated = Bytes[0x00, 0x01, 0x78, 0x05, 0x61, 0x62]

    expect_raises(HPack::Error, "invalid compression") do
      HPack::Decoder.new(max_decoded_string_size: 4).decode(truncated)
    end
  end

  it "does not apply the cap to strings retained in table state" do
    decoder = HPack::Decoder.new(max_decoded_string_size: 0)
    decoder.decode(Bytes[0x82]).should eq HTTP::Headers{":method" => "GET"}

    decoder.table.add("long-name", "long-retained-value")
    decoder.decode(Bytes[0xbe]).should eq HTTP::Headers{
      "long-name" => "long-retained-value",
    }
  end

  it "enforces the cap on every public decode path" do
    over_cap = Bytes[0x00, 0x01, 0x78, 0x03, 0x61, 0x62, 0x63]

    expect_raises(HPack::ResourceLimitError) do
      HPack::Decoder.new(max_decoded_string_size: 2).decode(over_cap)
    end
    expect_raises(HPack::ResourceLimitError) do
      HPack::Decoder.new(max_decoded_string_size: 2).decode_with_metadata(over_cap)
    end
    expect_raises(HPack::ResourceLimitError) do
      HPack::Decoder.new(max_decoded_string_size: 2).decode_each(over_cap) { }
    end
  end

  it "keeps ResourceLimitError distinct from compression errors" do
    error = HPack::ResourceLimitError.new("capped")

    error.should be_a(Exception)
    error.should_not be_a(HPack::Error)
  end

  it "decodes a Huffman literal when the cap is Int32::MAX" do
    HPack::Decoder.new(max_decoded_string_size: Int32::MAX)
      .decode(RFC_HUFFMAN_REQUEST)[":authority"].should eq "www.example.com"
  end
end
