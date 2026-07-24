require "./spec_helper"

private def resize_encoder_elsewhere(encoder : HPack::Encoder)
  encoder.resize_table(0)
end

private def reduce_decoder_limit_elsewhere(decoder : HPack::Decoder)
  decoder.max_table_size = 0
end

describe "codec reference semantics" do
  it "keeps encoder state coherent when passed to another method" do
    encoder = HPack::Encoder.new
    resize_encoder_elsewhere(encoder)

    encoder.table.maximum.should eq 0
    encoder.encode([] of Tuple(String, String)).should eq Bytes[0x20]
  end

  it "keeps decoder state coherent when passed to another method" do
    decoder = HPack::Decoder.new
    reduce_decoder_limit_elsewhere(decoder)

    decoder.max_table_size.should eq 0
    expect_raises(HPack::Error, /required dynamic table size update/) do
      decoder.decode(Bytes[0x82])
    end
  end
end
