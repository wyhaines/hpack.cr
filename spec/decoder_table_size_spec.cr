require "./spec_helper"

describe HPack::Decoder do
  describe "#max_table_size=" do
    it "validates assigned limits without resizing the table immediately" do
      decoder = HPack::Decoder.new

      expect_raises(ArgumentError, /table size/) do
        decoder.max_table_size = -1
      end
      expect_raises(ArgumentError, /table size/) do
        decoder.max_table_size = Int64::MAX
      end
      expect_raises(ArgumentError, /table size/) do
        decoder.max_table_size = UInt32::MAX
      end
      expect_raises(ArgumentError, /table size/) do
        decoder.max_table_size = UInt64::MAX
      end

      decoder.max_table_size = 1024_u32
      decoder.max_table_size.should eq 1024
      decoder.table.maximum.should eq 4096
    end

    it "requires a conforming update after reducing the active limit" do
      decoder = HPack::Decoder.new
      decoder.max_table_size = 1024

      expect_raises(HPack::Error, /required dynamic table size update/) do
        decoder.decode(Bytes[0x82])
      end
    end

    it "accepts a required update before the first header" do
      decoder = HPack::Decoder.new
      decoder.max_table_size = 1024

      headers = decoder.decode(Bytes[0x3f, 0xe1, 0x07, 0x82])

      headers.should eq HTTP::Headers{":method" => "GET"}
      decoder.table.maximum.should eq 1024
      decoder.decode(Bytes[0x82]).should eq HTTP::Headers{":method" => "GET"}
    end

    it "retains the lowest requirement across a later increase" do
      decoder = HPack::Decoder.new
      decoder.max_table_size = 1024
      decoder.max_table_size = 2048

      expect_raises(HPack::Error, /required dynamic table size update/) do
        decoder.decode(Bytes[0x3f, 0xe1, 0x0f, 0x82])
      end
    end

    it "accepts the required minimum followed by a final increase" do
      decoder = HPack::Decoder.new
      decoder.max_table_size = 1024
      decoder.max_table_size = 2048

      headers = decoder.decode(Bytes[
        0x3f, 0xe1, 0x07,
        0x3f, 0xe1, 0x0f,
        0x82,
      ])

      headers.should eq HTTP::Headers{":method" => "GET"}
      decoder.table.maximum.should eq 2048
    end

    it "accepts a single update below the required reduction" do
      decoder = HPack::Decoder.new
      decoder.max_table_size = 1024
      decoder.max_table_size = 2048

      headers = decoder.decode(Bytes[0x3f, 0xe1, 0x03, 0x82])

      headers.should eq HTTP::Headers{":method" => "GET"}
      decoder.table.maximum.should eq 512
    end

    it "does not require an update when peer capacity is already small enough" do
      decoder = HPack::Decoder.new
      decoder.decode(Bytes[0x3f, 0xe1, 0x03])
      decoder.table.maximum.should eq 512

      decoder.max_table_size = 1024

      decoder.decode(Bytes[0x82]).should eq HTTP::Headers{":method" => "GET"}
      decoder.table.maximum.should eq 512
    end

    it "requires an update in an otherwise empty block" do
      decoder = HPack::Decoder.new
      decoder.max_table_size = 0

      expect_raises(HPack::Error, /required dynamic table size update/) do
        decoder.decode(Bytes.empty)
      end

      decoder = HPack::Decoder.new
      decoder.max_table_size = 0
      decoder.decode(Bytes[0x20]).should be_empty
      decoder.decode(Bytes.empty).should be_empty
    end

    it "rejects updates above the active protocol limit" do
      decoder = HPack::Decoder.new(1024)

      expect_raises(HPack::Error, /larger than SETTINGS_HEADER_TABLE_SIZE/) do
        decoder.decode(Bytes[0x3f, 0xe1, 0x0f])
      end
    end

    it "rejects more than two updates at the beginning of a block" do
      decoder = HPack::Decoder.new

      expect_raises(HPack::Error, /too many dynamic table size updates/) do
        decoder.decode(Bytes[0x20, 0x20, 0x20, 0x82])
      end
    end

    it "reports malformed input after a conforming update" do
      decoder = HPack::Decoder.new
      decoder.max_table_size = 0

      expect_raises(HPack::Error, "invalid compression") do
        decoder.decode(Bytes[0x20, 0x00])
      end
    end
  end
end
