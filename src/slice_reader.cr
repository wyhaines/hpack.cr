module HPack
  # :nodoc:
  class SliceReader
    getter offset : Int32
    getter bytes : Bytes

    def initialize(@bytes : Bytes)
      @offset = 0
    end

    # Rebinds this reader to scan *bytes* from the beginning, so a single
    # instance can be reused across multiple decode calls instead of
    # allocating a fresh reader each time.
    def reset(bytes : Bytes) : Nil
      @bytes = bytes
      @offset = 0
    end

    @[AlwaysInline]
    def done?
      offset >= bytes.size
    end

    @[AlwaysInline]
    def current_byte
      bytes[offset]
    end

    @[AlwaysInline]
    def read_byte
      current_byte.tap { @offset += 1 }
    end

    def read(count)
      bytes[offset, count].tap { @offset += count }
    end
  end
end
