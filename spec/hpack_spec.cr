require "./spec_helper"

describe HPack do
  it "preserves never-indexed fields when metadata is used for re-encoding" do
    encoded = UInt8.static_array(
      0x82, 0x1f, 0x08, 0x06, 0x73, 0x65, 0x63, 0x72,
      0x65, 0x74,
    ).to_slice
    decoded = HPack::Decoder.new.decode_with_metadata(encoded)
    writer = IO::Memory.new
    encoder = HPack::Encoder.new

    decoded[:fields].each do |field|
      headers = HTTP::Headers{field.name => field.value}
      encoder.encode(headers, field.indexing, _writer: writer)
    end

    forwarded = HPack::Decoder.new.decode_with_metadata(writer.to_slice)
    forwarded[:headers].should eq decoded[:headers]
    forwarded[:fields].should eq decoded[:fields]
  end
end
