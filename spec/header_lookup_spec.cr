require "./spec_helper"

class HPack::Encoder
  # :nodoc:
  def lookup_for_spec(name : String, value : String)
    indexed(name, value)
  end
end

describe "HPack::Encoder header lookup" do
  it "finds every canonical static entry at its RFC index" do
    encoder = HPack::Encoder.new

    HPack::STATIC_TABLE.each_with_index do |header, offset|
      encoder.lookup_for_spec(header[0], header[1]).should eq({
        offset + 1,
        header[1],
      })
    end
  end

  it "uses the first static index for name-only matches" do
    encoder = HPack::Encoder.new
    first_indices = {} of String => Int32
    HPack::STATIC_TABLE.each_with_index do |header, offset|
      first_indices[header[0]] ||= offset + 1
    end

    first_indices.each do |name, index|
      encoder.lookup_for_spec(name, "__hpack_noncanonical__").should eq({
        index,
        nil,
      })
    end
  end

  it "uses indexed representations for canonical empty static values" do
    HPack::STATIC_TABLE.each_with_index do |header, offset|
      next unless header[1].empty?

      index = offset + 1
      encoded = HPack::Encoder.new.encode([{header[0], header[1]}])

      encoded.should eq Bytes[0x80_u8 | index.to_u8]
      HPack::Decoder.new.decode(encoded).should eq HTTP::Headers{
        header[0] => header[1],
      }
    end
  end

  [
    {
      HPack::Indexing::ALWAYS,
      false,
      Bytes[0x7e, 0x03, 0x6e, 0x65, 0x77],
    },
    {
      HPack::Indexing::ALWAYS,
      true,
      Bytes[0x7e, 0x83, 0xa8, 0xbe, 0x3f],
    },
    {
      HPack::Indexing::NONE,
      false,
      Bytes[0x0f, 0x2f, 0x03, 0x6e, 0x65, 0x77],
    },
    {
      HPack::Indexing::NONE,
      true,
      Bytes[0x0f, 0x2f, 0x83, 0xa8, 0xbe, 0x3f],
    },
    {
      HPack::Indexing::NEVER,
      false,
      Bytes[0x1f, 0x2f, 0x03, 0x6e, 0x65, 0x77],
    },
    {
      HPack::Indexing::NEVER,
      true,
      Bytes[0x1f, 0x2f, 0x83, 0xa8, 0xbe, 0x3f],
    },
  ].each do |indexing, huffman, expected|
    it "reuses a dynamic name with #{indexing} and huffman=#{huffman}" do
      encoder = HPack::Encoder.new
      encoder.table.add("x-custom", "old")

      encoded = encoder.encode(
        [{"x-custom", "new"}],
        indexing: indexing,
        huffman: huffman
      )

      encoded.should eq expected

      decoder = HPack::Decoder.new
      decoder.table.add("x-custom", "old")
      decoded = decoder.decode_with_metadata(encoded)
      decoded[:headers].should eq HTTP::Headers{"x-custom" => "new"}
      decoded[:fields][0].indexing.should eq indexing

      expected_size = indexing == HPack::Indexing::ALWAYS ? 2 : 1
      encoder.table.size.should eq expected_size
      decoder.table.size.should eq expected_size
      if indexing == HPack::Indexing::ALWAYS
        encoder.table[0].should eq({"x-custom", "new"})
        decoder.table[0].should eq({"x-custom", "new"})
      end
    end
  end

  it "uses the newest duplicate dynamic entry" do
    older_exact = HPack::Encoder.new
    older_exact.table.add("x-repeated", "target")
    older_exact.table.add("x-repeated", "newer-value")
    older_exact.lookup_for_spec("x-repeated", "target").should eq({
      HPack::STATIC_TABLE_SIZE + 2,
      "target",
    })

    encoder = HPack::Encoder.new
    encoder.table.add("x-repeated", "same")
    encoder.table.add("x-other", "middle")
    encoder.table.add("x-repeated", "same")

    encoder.lookup_for_spec("x-repeated", "same").should eq({
      HPack::STATIC_TABLE_SIZE + 1,
      "same",
    })
    encoder.lookup_for_spec("x-repeated", "new").should eq({
      HPack::STATIC_TABLE_SIZE + 1,
      nil,
    })
  end

  it "prefers an exact dynamic value but a static name index" do
    static_exact = HPack::Encoder.new
    static_exact.table.add(":method", "GET")
    static_exact.lookup_for_spec(":method", "GET").should eq({
      2,
      "GET",
    })

    encoder = HPack::Encoder.new
    encoder.table.add("cache-control", "private")

    encoder.lookup_for_spec("cache-control", "private").should eq({
      HPack::STATIC_TABLE_SIZE + 1,
      "private",
    })
    encoder.lookup_for_spec("cache-control", "no-cache").should eq({
      24,
      nil,
    })
  end

  it "adjusts dynamic indices as newer entries are inserted" do
    encoder = HPack::Encoder.new
    encoder.table.add("x-target", "value")
    encoder.lookup_for_spec("x-target", "value").should eq({
      HPack::STATIC_TABLE_SIZE + 1,
      "value",
    })

    encoder.table.add("x-newer", "value")
    encoder.lookup_for_spec("x-target", "value").should eq({
      HPack::STATIC_TABLE_SIZE + 2,
      "value",
    })
  end

  it "finds an exact dynamic match deeper than the linear-scan window" do
    encoder = HPack::Encoder.new
    20.times { |i| encoder.table.add("x-depth-#{i}", "value-#{i}") }

    # "x-depth-0" is the oldest entry (added first, unshifted to the back),
    # far beyond any reasonable scan-window size; this exercises the hash
    # index fallback path rather than the newest-entries linear scan.
    encoder.lookup_for_spec("x-depth-0", "value-0").should eq({
      HPack::STATIC_TABLE_SIZE + 20,
      "value-0",
    })
  end

  it "tracks dynamic lookup through eviction, clear, and resize" do
    encoder = HPack::Encoder.new(max_table_size: 108)
    encoder.table.add("a", "one")
    encoder.table.add("b", "two")
    encoder.table.add("c", "tri")

    encoder.lookup_for_spec("a", "one").should eq({
      HPack::STATIC_TABLE_SIZE + 3,
      "one",
    })

    encoder.table.add("d", "for")
    encoder.lookup_for_spec("a", "one").should be_nil
    encoder.lookup_for_spec("b", "two").should eq({
      HPack::STATIC_TABLE_SIZE + 3,
      "two",
    })
    encoder.lookup_for_spec("d", "for").should eq({
      HPack::STATIC_TABLE_SIZE + 1,
      "for",
    })

    encoder.table.resize(72)
    encoder.lookup_for_spec("b", "two").should be_nil
    encoder.lookup_for_spec("c", "tri").should eq({
      HPack::STATIC_TABLE_SIZE + 2,
      "tri",
    })
    encoder.lookup_for_spec("d", "for").should eq({
      HPack::STATIC_TABLE_SIZE + 1,
      "for",
    })

    encoder.table.resize(36)
    encoder.lookup_for_spec("c", "tri").should be_nil
    encoder.lookup_for_spec("d", "for").should eq({
      HPack::STATIC_TABLE_SIZE + 1,
      "for",
    })

    encoder.table.clear
    encoder.lookup_for_spec("d", "for").should be_nil
  end

  it "encodes the static 61 and dynamic 62 prefix boundaries" do
    static_expected = {
      HPack::Indexing::ALWAYS => Bytes[
        0x7d, 0x09, 0x63, 0x68, 0x61, 0x6c, 0x6c, 0x65, 0x6e, 0x67, 0x65,
      ],
      HPack::Indexing::NONE => Bytes[
        0x0f, 0x2e, 0x09, 0x63, 0x68, 0x61, 0x6c, 0x6c, 0x65, 0x6e, 0x67, 0x65,
      ],
      HPack::Indexing::NEVER => Bytes[
        0x1f, 0x2e, 0x09, 0x63, 0x68, 0x61, 0x6c, 0x6c, 0x65, 0x6e, 0x67, 0x65,
      ],
    }

    static_expected.each do |indexing, expected|
      encoded = HPack::Encoder.new.encode(
        [{"www-authenticate", "challenge"}],
        indexing: indexing
      )
      encoded.should eq expected

      decoded = HPack::Decoder.new.decode_with_metadata(encoded)
      decoded[:headers].should eq HTTP::Headers{
        "www-authenticate" => "challenge",
      }
      decoded[:fields][0].indexing.should eq indexing
    end

    HPack::Encoder.new.encode([{"www-authenticate", ""}]).should eq Bytes[0xbd]

    encoder = HPack::Encoder.new
    encoder.table.add("x-custom", "old")
    encoder.encode(
      [{"x-custom", "new"}],
      indexing: HPack::Indexing::NONE
    ).should eq Bytes[0x0f, 0x2f, 0x03, 0x6e, 0x65, 0x77]
  end
end

describe HPack::DynamicTable do
  it "finds exact and name-only matches by relative index" do
    table = HPack::DynamicTable.new(4096)
    table.add("x-a", "1") # index 2 after next add
    table.add("x-b", "2") # index 1
    table.find_index("x-b", "2").should eq 1
    table.find_index("x-a", "1").should eq 2
    table.find_index("x-a", "9").should be_nil
    table.find_name_index("x-a").should eq 2
  end

  it "prefers the newest duplicate and survives eviction of older ones" do
    # Room for both "k"/"v" entries (34 bytes each = 68) plus the "z" entry
    # (53 bytes) minus exactly one evicted 34-byte entry: 68 + 53 - 34 = 87.
    # Capacity 90 forces eviction of only the oldest duplicate.
    table = HPack::DynamicTable.new(90)
    table.add("k", "v")
    table.add("k", "v") # duplicate, newest wins
    table.find_index("k", "v").should eq 1
    table.add("z", "long-enough-to-evict") # evicts only the oldest "k"
    table.find_index("k", "v").should eq 2 # survivor still findable
  end
end
