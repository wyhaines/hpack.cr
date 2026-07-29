require "./slice_reader"
require "./error"
require "./indexing"
require "./header_field"

module HPack
  # The result of one `Decoder#decode_each` call.
  #
  # `decoded_size` is the HTTP/2 field-section size of the whole block: the
  # sum of `name.bytesize + value.bytesize + 32` over every decoded field,
  # including fields suppressed after the limit was crossed. `limit_exceeded`
  # is true when a configured `max_field_section_size` was crossed.
  record DecodeResult,
    decoded_size : UInt64,
    limit_exceeded : Bool

  # To decode headers, use a `HPack::Decoder` instance. By default, a decoder is created with a 4k (4096 bytes) table size. That table size can be changed in the constructor.
  #
  # ```
  # # To create a default Decoder:
  # decoder = HPack::Decoder.new
  #
  # # To create a decoder with a larger table size:
  # decoder = HPack::Decoder.new(8192)
  #
  # # To create a decoder that refuses to materialize any single literal
  # # larger than 64 KiB:
  # decoder = HPack::Decoder.new(max_decoded_string_size: 64 * 1024)
  #
  # # To decode headers:
  # headers = decoder.decode(bytes)
  #
  # # To decode headers into an existing `HTTP::Headers` instance:
  # headers = decoder.decode(bytes, HTTP::Headers.new)
  #
  # # To decode with a decompressed field-section budget:
  # result = decoder.decode_each(bytes, max_field_section_size: 64 * 1024) do |field|
  #   # Validate or retain this ordered field.
  # end
  # result.limit_exceeded # => false
  # ```
  class Decoder
    private getter! reader : SliceReader
    getter table : DynamicTable
    getter max_table_size : Int32

    # The hard cap applied to every decoded literal name and value, or `nil`
    # when literals are unbounded.
    getter max_decoded_string_size : Int32?

    @required_table_size_update : Int32?

    # Reusable scratch buffer for Huffman-decoded string output. Grows
    # (doubling via `Math.pw2ceil`) as needed and is never shrunk.
    @string_scratch : Bytes

    def initialize(max_table_size = 4096, max_decoded_string_size : Int? = nil)
      @max_table_size = normalize_table_size(max_table_size)
      @max_decoded_string_size =
        normalize_decoded_string_size(max_decoded_string_size)
      @table = DynamicTable.new(@max_table_size)
      @required_table_size_update = nil
      @string_scratch = Bytes.new(256)
    end

    # Changes the protocol limit for dynamic-table size updates.
    #
    # Reducing this limit below the peer's current table capacity requires a
    # conforming update at the beginning of the next decoded field block. The
    # table itself is resized only when that instruction is received.
    def max_table_size=(size : Int)
      normalized_size = normalize_table_size(size)
      if normalized_size < table.maximum
        @required_table_size_update =
          if required_size = @required_table_size_update
            normalized_size < required_size ? normalized_size : required_size
          else
            normalized_size
          end
      end
      @max_table_size = normalized_size
    end

    # Decodes *bytes* and adds each field to *headers*.
    #
    # Output is unlimited; use `#decode_each` with `max_field_section_size`
    # to bound the decompressed size of untrusted field blocks.
    def decode(bytes, headers = HTTP::Headers.new)
      decode_each(bytes) do |field|
        headers.add(field.name, field.value)
      end
      headers
    end

    # Decodes headers and retains their ordered indexing representations.
    #
    # The returned `headers` value is the same value returned by `#decode`.
    # `fields` retains one entry per decoded field, including `Indexing::NEVER`
    # markers that intermediaries need when forwarding fields.
    def decode_with_metadata(bytes, headers = HTTP::Headers.new)
      fields = [] of DecodedHeader
      decode_each(bytes) do |field|
        headers.add(field.name, field.value)
        fields << field
      end
      {headers: headers, fields: fields}
    end

    # Decodes *bytes*, yielding one `DecodedHeader` per field in wire order.
    #
    # Yielded names and values are ordinary immutable strings and remain
    # valid after the callback; no header collection is retained internally.
    #
    # `max_field_section_size` bounds the decompressed output using the
    # HTTP/2 field-section size rule (`name.bytesize + value.bytesize + 32`
    # per field). A total exactly equal to the limit is accepted. The field
    # that crosses the limit is not yielded and neither is any later field,
    # but the rest of the block is still parsed and dynamic-table insertions
    # and size updates are still applied, so the compression context stays
    # synchronized with the peer. `nil` means unlimited.
    #
    # If the callback raises, the first exception is saved, no later field is
    # yielded, and the remainder of the block is still decoded. A malformed
    # remainder raises `Error` and a resource cap raises `ResourceLimitError`;
    # otherwise the saved callback exception is re-raised after the block has
    # been fully decompressed, leaving the decoder reusable.
    #
    # Returns a `DecodeResult` carrying the final decoded size and whether
    # the limit was crossed. Callers should not publish the field section to
    # application code until `limit_exceeded` is known.
    #
    # ```
    # result = decoder.decode_each(
    #   encoded,
    #   max_field_section_size: 64 * 1024,
    # ) do |field|
    #   # Validate or retain this ordered field.
    # end
    # ```
    def decode_each(
      bytes,
      max_field_section_size : Int? = nil,
      & : DecodedHeader ->
    ) : DecodeResult
      limit = normalize_field_section_limit(max_field_section_size)
      callback_error = nil.as(Exception?)

      result =
        begin
          @reader = SliceReader.new(bytes)
          decoded_header = false
          table_size_update_count = 0
          decoded_size = 0_u64
          limit_exceeded = false
          ensure_required_table_size_update

          until reader.done?
            if reader.current_byte & 0xe0_u8 == 0x20_u8 # 001.....  table max size update
              raise Error.new("unexpected dynamic table size update") if decoded_header
              table_size_update_count =
                apply_dynamic_table_size_update(table_size_update_count)
              next
            end

            name, value, indexing = parse_representation
            decoded_header = true
            decoded_size = add_field_size(decoded_size, name, value)
            limit_exceeded = true if limit && decoded_size > limit

            unless limit_exceeded || callback_error
              begin
                yield DecodedHeader.new(name, value, indexing)
              rescue ex
                callback_error = ex
              end
            end
          end

          @required_table_size_update = nil
          DecodeResult.new(decoded_size, limit_exceeded)
        rescue IndexError
          raise Error.new("invalid compression")
        end

      if error = callback_error
        raise error
      end
      result
    end

    # Parses one non-update representation and returns its decoded name,
    # value, and `Indexing` marker. The caller has already consumed any
    # dynamic table size updates.
    @[AlwaysInline]
    private def parse_representation : {String, String, Indexing}
      if reader.current_byte.bit(7) == 1 # 1.......  indexed
        _index, name, value = literal_indexed
        {name, value, Indexing::INDEXED}
      elsif reader.current_byte.bit(6) == 1 # 01......  literal with incremental indexing
        _index, name, value = literal_with_incremental_indexing
        {name, value, Indexing::ALWAYS}
      elsif reader.current_byte.bit(4) == 1 # 0001....  literal never indexed
        _index, name, value = literal_never_indexed
        {name, value, Indexing::NEVER}
      else # 0000....  literal without indexing
        _index, name, value = literal_without_indexing
        {name, value, Indexing::NONE}
      end
    end

    private def normalize_table_size(size : Int) : Int32
      if size < 0 || size > Int32::MAX
        raise ArgumentError.new(
          "table size must be between 0 and #{Int32::MAX}: #{size}"
        )
      end

      size.to_i32
    end

    private def normalize_decoded_string_size(size : Int?) : Int32?
      return nil if size.nil?
      if size < 0 || size > Int32::MAX
        raise ArgumentError.new(
          "decoded string size cap must be between 0 and #{Int32::MAX}: #{size}"
        )
      end

      size.to_i32
    end

    private def normalize_field_section_limit(limit : Int?) : UInt64?
      return nil if limit.nil?
      if limit < 0 || limit > UInt64::MAX
        raise ArgumentError.new(
          "field-section size limit must be between 0 and #{UInt64::MAX}: #{limit}"
        )
      end

      limit.to_u64
    end

    private def add_field_size(total : UInt64, name : String, value : String) : UInt64
      total + (name.bytesize.to_u64 + value.bytesize.to_u64 + 32_u64)
    rescue OverflowError
      raise ResourceLimitError.new(
        "decoded field-section size exceeds UInt64 accounting"
      )
    end

    @[AlwaysInline]
    private def ensure_required_table_size_update
      return unless @required_table_size_update
      unless reader.done?
        return if reader.current_byte & 0xe0_u8 == 0x20_u8
      end

      raise Error.new("required dynamic table size update is missing")
    end

    private def apply_dynamic_table_size_update(update_count : Int32)
      update_count += 1
      if update_count > 2
        raise Error.new("too many dynamic table size updates")
      end

      new_size = integer(5)
      if new_size > max_table_size
        raise Error.new(
          "dynamic table size update is larger than " \
          "SETTINGS_HEADER_TABLE_SIZE (#{max_table_size})"
        )
      end
      if update_count == 1
        if required_size = @required_table_size_update
          if new_size > required_size
            raise Error.new(
              "required dynamic table size update exceeds #{required_size}"
            )
          end
        end
      end

      table.resize(new_size)
      update_count
    end

    @[AlwaysInline]
    def literal_indexed
      index = integer(7)
      raise Error.new("invalid index: 0") if index == 0
      name, value = indexed(index)
      {index, name, value}
    end

    @[AlwaysInline]
    def literal_with_incremental_indexing
      index = integer(6)
      name = index == 0 ? string : indexed(index).first
      value = string
      table.add(name, value)
      {index, name, value}
    end

    @[AlwaysInline]
    def literal_never_indexed
      index = integer(4)
      name = index == 0 ? string : indexed(index).first
      value = string
      {index, name, value}
    end

    @[AlwaysInline]
    def literal_without_indexing
      index = integer(4)
      name = index == 0 ? string : indexed(index).first
      value = string
      {index, name, value}
    end

    def indexed(index)
      if 0 < index <= STATIC_TABLE_SIZE
        return STATIC_TABLE[index - 1]
      end

      if header = table[index - STATIC_TABLE_SIZE - 1]?
        return header
      end

      raise Error.new("invalid index: #{index}")
    end

    def integer(n)
      prefix_maximum = (1 << n) - 1
      value = reader.read_byte.to_i32 & prefix_maximum
      return value if value < prefix_maximum

      integer = value.to_i64
      maximum = Int32::MAX.to_i64
      multiplier = 1_i64
      beyond_limit = false
      loop do
        byte = reader.read_byte
        digit = (byte & 127).to_i64
        if beyond_limit
          raise Error.new("integer exceeds implementation limit") unless digit == 0
        else
          increment = digit * multiplier
          if increment > maximum - integer
            raise Error.new("integer exceeds implementation limit")
          end
          integer += increment
        end
        break unless byte & 128 == 128

        if multiplier > maximum // 128
          beyond_limit = true
        else
          multiplier *= 128
        end
      end

      integer.to_i32
    end

    def string
      huffman = reader.current_byte.bit(7) == 1
      length = integer(7)
      bytes = reader.read(length)

      if huffman
        huffman_string(bytes)
      else
        if (cap = @max_decoded_string_size) && length > cap
          raise ResourceLimitError.new(
            "decoded string of #{length} bytes exceeds the configured cap (#{cap})"
          )
        end
        String.new(bytes)
      end
    end

    # Huffman-decodes *encoded* into the reusable `@string_scratch` buffer,
    # growing it (by doubling via `Math.pw2ceil`) only when it is too small.
    #
    # When `max_decoded_string_size` is configured, the destination is sized
    # to `cap + 1` at most (rather than the full worst-case bound), so an
    # expanding literal is stopped at roughly the configured cap instead of
    # allocating scratch space for the entire decoded output; the `+ 1`
    # keeps a decoded length of exactly `cap + 1` bytes distinguishable from
    # one that fits, since `Huffman#decode` only returns `-1` once *dest*
    # itself is too small to hold another byte.
    private def huffman_string(encoded : Bytes) : String
      cap = @max_decoded_string_size
      bound = encoded.size * 8 // 5 + 1
      bound = Math.min(bound, cap + 1) if cap

      if @string_scratch.size < bound
        @string_scratch = Bytes.new(Math.pw2ceil(bound))
      end

      n = HPack.huffman.decode(encoded, @string_scratch[0, bound])
      if n < 0 || (cap && n > cap)
        raise ResourceLimitError.new(
          "decoded string exceeds the configured cap (#{cap})"
        )
      end

      String.new(@string_scratch[0, n])
    end
  end
end
