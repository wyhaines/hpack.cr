module HPack
  # Raised for malformed HPACK input: truncated blocks, invalid indexes,
  # protocol-violating table-size updates, and similar compression errors.
  class Error < Exception
  end

  # Raised when decoding would exceed a locally configured resource limit,
  # such as the hard decoded-string cap or checked size accounting.
  #
  # This is deliberately not a subclass of `Error`: the input may be valid
  # HPACK that this decoder refuses to materialize. A block that fails with
  # this error was not fully decompressed, so the decoder's compression
  # context is stale and the decoder must be discarded.
  class ResourceLimitError < Exception
  end
end
