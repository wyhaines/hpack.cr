require "./indexing"

module HPack
  # Controls Huffman encoding for strings emitted in a header field.
  enum HuffmanMode : UInt8
    # Always emit the raw string.
    NEVER

    # Always emit the Huffman representation.
    ALWAYS

    # Emit Huffman data only when its encoded byte length is strictly smaller.
    SMALLER
  end

  # Optional indexing and Huffman overrides returned by an encoder policy block.
  #
  # ```
  # options = HPack::FieldOptions.new(
  #   indexing: HPack::Indexing::NEVER,
  #   huffman: HPack::HuffmanMode::SMALLER
  # )
  # ```
  record FieldOptions,
    indexing : Indexing? = nil,
    huffman : HuffmanMode? = nil

  # An ordered header field with optional per-field encoding overrides.
  #
  # Explicit values take precedence over policy-block and per-call values.
  #
  # ```
  # field = HPack::HeaderField.new(
  #   "authorization",
  #   "secret",
  #   indexing: HPack::Indexing::NEVER
  # )
  # ```
  record HeaderField,
    name : String,
    value : String,
    indexing : Indexing? = nil,
    huffman : HuffmanMode? = nil

  # A decoded header field together with its representation on the wire.
  #
  # Intermediaries must preserve `Indexing::NEVER` when re-encoding a field.
  record DecodedHeader,
    name : String,
    value : String,
    indexing : Indexing
end
