require "./indexing"
require "./header_field"
require "./dynamic_table"
require "./static_table"
require "./huffman"
{% if flag?(:preview_mt) %}
  require "mutex"
{% end %}

module HPack
  # The default Encoder will be created with Indexing set to [`NONE`](https://httpwg.org/specs/rfc7541.html#literal.header.without.indexing), huffman encoding false, and the max table size set to 4k (4096 bytes). These parameters can all be set in the constructor.
  #
  # ```
  # # To create a default Encoder:
  # encoder = HPack::Encoder.new
  #
  # # To create an encoder with indexing set to Always and Huffman encoding set to true:
  # encoder = HPack::Encoder.new(indexing: HPack::Indexing::ALWAYS, huffman: true)
  # encoder = HPack::Encoder.new(HPack::Indexing::ALWAYS, true)
  #
  # # To create an encoder with the max table size set to 8 KiB (8192 bytes):
  # encoder = HPack::Encoder.new(HPack::Indexing::ALWAYS, true, 8192)
  #
  # # To encode headers:
  # encoder.encode(
  #   HTTP::Headers{
  #     ":status"       => "302",
  #     "cache-control" => "private",
  #     "date"          => "Mon, 21 Oct 2013 20:13:21 GMT",
  #     "location"      => "https://www.example.com",
  #   }
  # )
  # ```
  class Encoder
    private getter writer : IO
    @buffer : IO::Memory
    @pseudo_headers : Array(Tuple(String, Array(String)))
    @regular_headers : Array(Tuple(String, Array(String)))
    @table_snapshot : Array(Tuple(String, String))?
    @table_snapshot_maximum : Int32
    @table_transaction_active : Bool
    @table_snapshot_captured : Bool
    @pending_table_size_minimum : Int32?
    @pending_table_size_final : Int32?
    getter table : DynamicTable
    property default_indexing : Indexing
    # Retain the established getter name for API compatibility.
    property default_huffman : Bool # ameba:disable Naming/QueryBoolMethods
    {% if flag?(:preview_mt) %}
      @mutex = Mutex.new
    {% end %}

    def initialize(indexing = Indexing::NONE, huffman = false, max_table_size = 4096)
      normalized_max_table_size = normalize_table_size(max_table_size)
      @buffer = IO::Memory.new
      @writer = @buffer
      @pseudo_headers = [] of Tuple(String, Array(String))
      @regular_headers = [] of Tuple(String, Array(String))
      @table_snapshot = nil
      @table_snapshot_maximum = normalized_max_table_size
      @table_transaction_active = false
      @table_snapshot_captured = false
      @pending_table_size_minimum = nil
      @pending_table_size_final = nil
      @default_indexing = indexing
      @default_huffman = huffman
      @table = DynamicTable.new(normalized_max_table_size)
    end

    # Changes the dynamic-table capacity and queues the corresponding HPACK
    # size update for the beginning of the next encoded field block.
    #
    # The local table is resized immediately. Multiple changes before a block
    # are coalesced to the smallest requested size followed by the final size.
    # Pending updates are consumed only after a field block is encoded
    # successfully.
    #
    # Use this operation for negotiated capacity changes. Calling
    # `#table.resize` directly does not signal the peer decoder.
    def resize_table(size : Int) : Nil
      normalized_size = normalize_table_size(size)

      {% if flag?(:preview_mt) %}
        @mutex.synchronize { resize_table_unlocked(normalized_size) }
      {% else %}
        resize_table_unlocked(normalized_size)
      {% end %}
      nil
    end

    # Encodes *headers* and returns an owned byte slice.
    #
    # Pseudo-headers are emitted before regular headers regardless of their
    # insertion order. The returned bytes remain valid after later calls.
    #
    # The `_writer` argument is retained for compatibility. New code that owns
    # its output buffer should use `#encode_into`.
    def encode(
      headers : HTTP::Headers,
      indexing = default_indexing,
      huffman = default_huffman,
      _writer : IO::Memory? = nil,
    ) : Bytes
      if output = _writer
        encode_into(headers, output, indexing, huffman)
        return output.to_slice
      end

      {% begin %}
      {% if flag?(:preview_mt) %}
      @mutex.synchronize do
      {% end %}
      @buffer.clear
      with_writer(@buffer, indexing == Indexing::ALWAYS) do
        encode_headers(headers, indexing, huffman, false) { nil }
      end
      @buffer.to_slice.dup
      {% if flag?(:preview_mt) %}
      end
      {% end %}
      {% end %}
    end

    # Encodes *headers* using a policy evaluated once per field in wire order.
    #
    # The block receives the normalized name and value and may return
    # `FieldOptions` overrides. A `nil` return retains the per-call values.
    #
    # ```
    # encoder.encode(headers, huffman: HPack::HuffmanMode::SMALLER) do |name, _|
    #   if name == "authorization"
    #     HPack::FieldOptions.new(indexing: HPack::Indexing::NEVER)
    #   end
    # end
    # ```
    def encode(
      headers : HTTP::Headers,
      indexing : Indexing = default_indexing,
      huffman : Bool | HuffmanMode = default_huffman,
      & : String, String -> FieldOptions?
    ) : Bytes
      {% begin %}
      {% if flag?(:preview_mt) %}
      @mutex.synchronize do
      {% end %}
      validate_indexing(indexing)
      @buffer.clear
      with_writer(@buffer, true) do
        encode_headers(headers, indexing, huffman, true) do |name, value|
          yield name, value
        end
      end
      @buffer.to_slice.dup
      {% if flag?(:preview_mt) %}
      end
      {% end %}
      {% end %}
    end

    # Encodes ordered name/value *fields* and returns an owned byte slice.
    #
    # Fields are emitted in the supplied order and duplicate names are
    # preserved. Callers must place every pseudo-header before regular fields.
    # Use the `HTTP::Headers` overload when the encoder should perform that
    # reordering.
    def encode(
      fields : Enumerable(Tuple(String, String)),
      indexing = default_indexing,
      huffman = default_huffman,
    ) : Bytes
      {% begin %}
      {% if flag?(:preview_mt) %}
      @mutex.synchronize do
      {% end %}
      @buffer.clear
      with_writer(@buffer, indexing == Indexing::ALWAYS) do
        encode_tuple_fields(fields, indexing, huffman, false) { nil }
      end
      @buffer.to_slice.dup
      {% if flag?(:preview_mt) %}
      end
      {% end %}
      {% end %}
    end

    # Encodes ordered tuple *fields* using a per-field policy block.
    #
    # Fields remain in supplied order. The block receives normalized names and
    # may return `FieldOptions` overrides.
    def encode(
      fields : Enumerable(Tuple(String, String)),
      indexing : Indexing = default_indexing,
      huffman : Bool | HuffmanMode = default_huffman,
      & : String, String -> FieldOptions?
    ) : Bytes
      {% begin %}
      {% if flag?(:preview_mt) %}
      @mutex.synchronize do
      {% end %}
      validate_indexing(indexing)
      @buffer.clear
      with_writer(@buffer, true) do
        encode_tuple_fields(fields, indexing, huffman, true) do |name, value|
          yield name, value
        end
      end
      @buffer.to_slice.dup
      {% if flag?(:preview_mt) %}
      end
      {% end %}
      {% end %}
    end

    # Encodes ordered fields with optional per-field overrides.
    def encode(
      fields : Enumerable(HeaderField),
      indexing : Indexing = default_indexing,
      huffman : Bool | HuffmanMode = default_huffman,
    ) : Bytes
      {% begin %}
      {% if flag?(:preview_mt) %}
      @mutex.synchronize do
      {% end %}
      validate_indexing(indexing)
      @buffer.clear
      with_writer(@buffer, true) do
        encode_header_fields(fields, indexing, huffman) { nil }
      end
      @buffer.to_slice.dup
      {% if flag?(:preview_mt) %}
      end
      {% end %}
      {% end %}
    end

    # Encodes ordered fields with explicit options and a policy block.
    #
    # Each `HeaderField` option takes precedence over the corresponding
    # callback option, which takes precedence over the per-call value.
    def encode(
      fields : Enumerable(HeaderField),
      indexing : Indexing = default_indexing,
      huffman : Bool | HuffmanMode = default_huffman,
      & : String, String -> FieldOptions?
    ) : Bytes
      {% begin %}
      {% if flag?(:preview_mt) %}
      @mutex.synchronize do
      {% end %}
      validate_indexing(indexing)
      @buffer.clear
      with_writer(@buffer, true) do
        encode_header_fields(fields, indexing, huffman) do |name, value|
          yield name, value
        end
      end
      @buffer.to_slice.dup
      {% if flag?(:preview_mt) %}
      end
      {% end %}
      {% end %}
    end

    # Encodes decoded fields while preserving each field's indexing marker.
    #
    # Only Huffman behavior may be overridden; in particular,
    # `Indexing::NEVER` cannot be downgraded while forwarding.
    def encode(
      fields : Enumerable(DecodedHeader),
      *,
      huffman : Bool | HuffmanMode = default_huffman,
    ) : Bytes
      {% begin %}
      {% if flag?(:preview_mt) %}
      @mutex.synchronize do
      {% end %}
      @buffer.clear
      with_writer(@buffer, true) do
        encode_decoded_fields(fields, huffman)
      end
      @buffer.to_slice.dup
      {% if flag?(:preview_mt) %}
      end
      {% end %}
      {% end %}
    end

    # Appends one encoded block for *headers* to *output*.
    #
    # Existing output is not cleared. Pseudo-headers are emitted before regular
    # headers regardless of insertion order.
    def encode_into(
      headers : HTTP::Headers,
      output : IO,
      indexing = default_indexing,
      huffman = default_huffman,
    ) : Nil
      {% begin %}
      {% if flag?(:preview_mt) %}
      @mutex.synchronize do
      {% end %}
      with_writer(output, indexing == Indexing::ALWAYS) do
        encode_headers(headers, indexing, huffman, false) { nil }
      end
      {% if flag?(:preview_mt) %}
      end
      {% end %}
      {% end %}
      nil
    end

    # Appends a policy-driven encoded block for *headers* to *output*.
    #
    # Existing output is not cleared. The policy is evaluated once per field
    # after name normalization and pseudo-header ordering.
    def encode_into(
      headers : HTTP::Headers,
      output : IO,
      indexing : Indexing = default_indexing,
      huffman : Bool | HuffmanMode = default_huffman,
      & : String, String -> FieldOptions?
    ) : Nil
      {% begin %}
      {% if flag?(:preview_mt) %}
      @mutex.synchronize do
      {% end %}
      validate_indexing(indexing)
      with_writer(output, true) do
        encode_headers(headers, indexing, huffman, true) do |name, value|
          yield name, value
        end
      end
      {% if flag?(:preview_mt) %}
      end
      {% end %}
      {% end %}
      nil
    end

    # Appends one encoded block for ordered name/value *fields* to *output*.
    #
    # Existing output is not cleared, duplicate names are preserved, and fields
    # are emitted in the supplied order. Callers must place every pseudo-header
    # before regular fields.
    def encode_into(
      fields : Enumerable(Tuple(String, String)),
      output : IO,
      indexing = default_indexing,
      huffman = default_huffman,
    ) : Nil
      {% begin %}
      {% if flag?(:preview_mt) %}
      @mutex.synchronize do
      {% end %}
      with_writer(output, indexing == Indexing::ALWAYS) do
        encode_tuple_fields(fields, indexing, huffman, false) { nil }
      end
      {% if flag?(:preview_mt) %}
      end
      {% end %}
      {% end %}
      nil
    end

    # Appends policy-driven ordered tuple *fields* to *output*.
    def encode_into(
      fields : Enumerable(Tuple(String, String)),
      output : IO,
      indexing : Indexing = default_indexing,
      huffman : Bool | HuffmanMode = default_huffman,
      & : String, String -> FieldOptions?
    ) : Nil
      {% begin %}
      {% if flag?(:preview_mt) %}
      @mutex.synchronize do
      {% end %}
      validate_indexing(indexing)
      with_writer(output, true) do
        encode_tuple_fields(fields, indexing, huffman, true) do |name, value|
          yield name, value
        end
      end
      {% if flag?(:preview_mt) %}
      end
      {% end %}
      {% end %}
      nil
    end

    # Appends ordered fields with optional per-field overrides to *output*.
    def encode_into(
      fields : Enumerable(HeaderField),
      output : IO,
      indexing : Indexing = default_indexing,
      huffman : Bool | HuffmanMode = default_huffman,
    ) : Nil
      {% begin %}
      {% if flag?(:preview_mt) %}
      @mutex.synchronize do
      {% end %}
      validate_indexing(indexing)
      with_writer(output, true) do
        encode_header_fields(fields, indexing, huffman) { nil }
      end
      {% if flag?(:preview_mt) %}
      end
      {% end %}
      {% end %}
      nil
    end

    # Appends ordered fields using explicit options and a policy block.
    def encode_into(
      fields : Enumerable(HeaderField),
      output : IO,
      indexing : Indexing = default_indexing,
      huffman : Bool | HuffmanMode = default_huffman,
      & : String, String -> FieldOptions?
    ) : Nil
      {% begin %}
      {% if flag?(:preview_mt) %}
      @mutex.synchronize do
      {% end %}
      validate_indexing(indexing)
      with_writer(output, true) do
        encode_header_fields(fields, indexing, huffman) do |name, value|
          yield name, value
        end
      end
      {% if flag?(:preview_mt) %}
      end
      {% end %}
      {% end %}
      nil
    end

    # Appends decoded fields while preserving every indexing marker.
    def encode_into(
      fields : Enumerable(DecodedHeader),
      output : IO,
      *,
      huffman : Bool | HuffmanMode = default_huffman,
    ) : Nil
      {% begin %}
      {% if flag?(:preview_mt) %}
      @mutex.synchronize do
      {% end %}
      with_writer(output, true) do
        encode_decoded_fields(fields, huffman)
      end
      {% if flag?(:preview_mt) %}
      end
      {% end %}
      {% end %}
      nil
    end

    private def with_writer(output : IO, transactional : Bool, &)
      previous_writer = @writer
      @writer = output
      completed = false
      if transactional
        @table_transaction_active = true
        @table_snapshot_captured = false
      end

      begin
        emit_pending_table_size_updates
        yield
        completed = true
      ensure
        rollback_table if transactional && !completed
        clear_pending_table_size_updates if completed
        if transactional
          @table_transaction_active = false
          @table_snapshot_captured = false
          @table_snapshot.try(&.clear)
        end
        @writer = previous_writer
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

    private def resize_table_unlocked(size : Int32)
      return if table.maximum == size

      table.resize(size)
      @pending_table_size_minimum = if minimum = @pending_table_size_minimum
                                      size < minimum ? size : minimum
                                    else
                                      size
                                    end
      @pending_table_size_final = size
    end

    private def emit_pending_table_size_updates
      return unless minimum = @pending_table_size_minimum

      integer(minimum, 5, prefix: 0x20_u8)
      if final = @pending_table_size_final
        integer(final, 5, prefix: 0x20_u8) unless final == minimum
      end
    end

    private def clear_pending_table_size_updates
      @pending_table_size_minimum = nil
      @pending_table_size_final = nil
    end

    private def add_to_table(name : String, value : String)
      if @table_transaction_active && !@table_snapshot_captured
        if table.empty?
          @table_snapshot.try(&.clear)
        else
          snapshot = @table_snapshot ||= [] of Tuple(String, String)
          snapshot.clear
          table.each { |header| snapshot << header }
        end
        @table_snapshot_maximum = table.maximum
        @table_snapshot_captured = true
      end
      table.add(name, value)
    end

    private def rollback_table
      return unless @table_snapshot_captured

      table.maximum = @table_snapshot_maximum
      table.clear
      if snapshot = @table_snapshot
        snapshot.reverse_each do |name, value|
          table.add(name, value)
        end
      end
    end

    private def encode_headers(headers : HTTP::Headers, indexing, huffman, validate, &)
      headers.each do |name, values|
        partition = name.starts_with?(':') ? @pseudo_headers : @regular_headers
        partition << {normalize_name(name), values}
      end

      if validate
        huffman_mode = huffman_mode(huffman)
        @pseudo_headers.each do |name, values|
          values.each do |value|
            options = yield name, value
            encode_policy_field(
              name,
              value,
              nil,
              nil,
              options,
              indexing,
              huffman_mode,
              true
            )
          end
        end
        @regular_headers.each do |name, values|
          values.each do |value|
            options = yield name, value
            encode_policy_field(
              name,
              value,
              nil,
              nil,
              options,
              indexing,
              huffman_mode,
              true
            )
          end
        end
      else
        @pseudo_headers.each do |name, values|
          values.each do |value|
            yield name, value
            encode_field(name, value, indexing, huffman)
          end
        end
        @regular_headers.each do |name, values|
          values.each do |value|
            yield name, value
            encode_field(name, value, indexing, huffman)
          end
        end
      end
    ensure
      @pseudo_headers.clear
      @regular_headers.clear
    end

    private def encode_tuple_fields(
      fields : Enumerable(Tuple(String, String)),
      indexing,
      huffman,
      validate,
      &
    )
      if validate
        huffman_mode = huffman_mode(huffman)
        fields.each do |name, value|
          normalized_name = normalize_name(name)
          options = yield normalized_name, value
          encode_policy_field(
            normalized_name,
            value,
            nil,
            nil,
            options,
            indexing,
            huffman_mode,
            true
          )
        end
      else
        fields.each do |name, value|
          normalized_name = normalize_name(name)
          yield normalized_name, value
          encode_field(normalized_name, value, indexing, huffman)
        end
      end
    end

    private def encode_header_fields(
      fields : Enumerable(HeaderField),
      indexing : Indexing,
      huffman,
      &
    )
      huffman_mode = huffman_mode(huffman)
      fields.each do |field|
        normalized_name = normalize_name(field.name)
        options = yield normalized_name, field.value
        encode_policy_field(
          normalized_name,
          field.value,
          field.indexing,
          field.huffman,
          options,
          indexing,
          huffman_mode,
          true
        )
      end
    end

    private def encode_decoded_fields(fields : Enumerable(DecodedHeader), huffman)
      huffman_mode = huffman_mode(huffman)
      fields.each do |field|
        validate_indexing(field.indexing)
        encode_field(
          normalize_name(field.name),
          field.value,
          field.indexing,
          huffman_mode
        )
      end
    end

    private def encode_policy_field(
      name : String,
      value : String,
      explicit_indexing : Indexing?,
      explicit_huffman : HuffmanMode?,
      options : FieldOptions?,
      indexing : Indexing,
      huffman : HuffmanMode,
      validate : Bool,
    )
      if validate
        validate_indexing(explicit_indexing) if explicit_indexing
        if options
          if option_indexing = options.indexing
            validate_indexing(option_indexing)
          end
        end
      end

      resolved_indexing = explicit_indexing || options.try(&.indexing) || indexing
      resolved_huffman = explicit_huffman || options.try(&.huffman) || huffman
      encode_field(name, value, resolved_indexing, resolved_huffman)
    end

    private def huffman_mode(huffman : Bool) : HuffmanMode
      huffman ? HuffmanMode::ALWAYS : HuffmanMode::NEVER
    end

    private def huffman_mode(huffman : HuffmanMode) : HuffmanMode
      huffman
    end

    private def validate_indexing(indexing : Indexing)
      case indexing
      when Indexing::NONE, Indexing::INDEXED, Indexing::ALWAYS, Indexing::NEVER
        nil
      else
        raise ArgumentError.new("invalid indexing policy: #{indexing}")
      end
    end

    # HTTP/2 requires lowercase ASCII field names, while HPACK treats names as
    # opaque octets. Only the bytes A-Z are mapped; every other octet,
    # including non-ASCII and invalid UTF-8, passes through unchanged.
    private def normalize_name(name : String) : String
      needs_normalization = false
      name.each_byte do |byte|
        if 0x41_u8 <= byte <= 0x5a_u8
          needs_normalization = true
          break
        end
      end
      return name unless needs_normalization

      String.new(name.bytesize) do |buffer|
        name.to_slice.each_with_index do |byte, index|
          buffer[index] = 0x41_u8 <= byte <= 0x5a_u8 ? byte + 0x20_u8 : byte
        end
        {name.bytesize, 0}
      end
    end

    # :nodoc:
    protected def encode(name, values, indexing, huffman)
      values.each { |value| encode_field(name, value, indexing, huffman) }
    end

    # :nodoc:
    protected def encode_field(name, value, indexing, huffman)
      if header = indexed(name, value)
        if indexing == Indexing::NEVER
          integer(header[0], 4, prefix: Indexing::NEVER)
          string(value, huffman)
        elsif header[1]
          integer(header[0], 7, prefix: Indexing::INDEXED)
        elsif indexing == Indexing::ALWAYS
          integer(header[0], 6, prefix: Indexing::ALWAYS)
          string(value, huffman)
          add_to_table(name, value)
        else
          integer(header[0], 4, prefix: Indexing::NONE)
          string(value, huffman)
        end
      else
        case indexing
        when Indexing::ALWAYS
          add_to_table(name, value)
          writer.write_byte(Indexing::ALWAYS.value)
        when Indexing::NEVER
          writer.write_byte(Indexing::NEVER.value)
        else
          writer.write_byte(Indexing::NONE.value)
        end
        string(name, huffman)
        string(value, huffman)
      end
    end

    # Generate a compact fast path for pseudo-headers and bucket regular names
    # by length. STATIC_TABLE remains the only source of names, values, and
    # indexes.
    private macro static_indexed(name, value)
      {% begin %}
        {% names = [] of Nil %}
        {% regular_lengths = [] of Nil %}
        {% for header in STATIC_TABLE %}
          {% names << header[0] unless names.includes?(header[0]) %}
          {% unless header[0].starts_with?(":") %}
            {% regular_lengths << header[0].size unless regular_lengths.includes?(header[0].size) %}
          {% end %}
        {% end %}

        case {{ name }}
        {% for static_name in names %}
          {% if static_name.starts_with?(":") %}
            when {{ static_name }}
              {% first_index = nil %}
              {% for header, offset in STATIC_TABLE %}
                {% if header[0] == static_name %}
                  {% first_index ||= offset + 1 %}
                  return { {{ offset + 1 }}, {{ header[1] }} } if {{ value }} == {{ header[1] }}
                {% end %}
              {% end %}
              { {{ first_index }}, nil }
          {% end %}
        {% end %}
        else
          case {{ name }}.bytesize
          {% for length in regular_lengths.sort %}
          when {{ length }}
            case {{ name }}
            {% for static_name in names %}
              {% if !static_name.starts_with?(":") && static_name.size == length %}
                when {{ static_name }}
                  {% first_index = nil %}
                  {% for header, offset in STATIC_TABLE %}
                    {% if header[0] == static_name %}
                      {% first_index ||= offset + 1 %}
                      return { {{ offset + 1 }}, {{ header[1] }} } if {{ value }} == {{ header[1] }}
                    {% end %}
                  {% end %}
                  { {{ first_index }}, nil }
              {% end %}
            {% end %}
            end
          {% end %}
          end
        end
      {% end %}
    end

    protected def indexed(name : String, value : String)
      static_entry = static_indexed(name, value)

      dynamic_name_index = nil
      table.each_with_index do |header, index|
        next unless header[0] == name

        dynamic_index = index + STATIC_TABLE_SIZE + 1
        return {dynamic_index, header[1]} if header[1] == value
        dynamic_name_index ||= dynamic_index unless static_entry
      end

      if static_entry
        {static_entry[0], nil}
      elsif dynamic_name_index
        {dynamic_name_index, nil}
      end
    end

    protected def integer(integer : Int32, n, prefix = 0_u8)
      n2 = (1 << n) - 1
      if integer < n2
        writer.write_byte(integer.to_u8 | prefix.to_u8)
        return
      end

      writer.write_byte(n2.to_u8 | prefix.to_u8)
      integer -= n2

      while integer >= 128
        writer.write_byte(((integer & 0x7f) | 0x80).to_u8)
        integer >>= 7
      end

      writer.write_byte(integer.to_u8)
    end

    protected def string(string : String, huffman : Bool)
      if huffman
        encoded = HPack.huffman.encode(string)
        integer(encoded.size, 7, prefix: 128)
        writer.write(encoded)
      else
        integer(string.bytesize, 7)
        writer << string
      end
    end

    protected def string(
      string : String,
      huffman : HuffmanMode = HuffmanMode::NEVER,
    )
      use_huffman = huffman == HuffmanMode::ALWAYS ||
                    (huffman == HuffmanMode::SMALLER &&
                     HPack.huffman.encoded_size(string) < string.bytesize)
      if use_huffman
        encoded = HPack.huffman.encode(string)
        integer(encoded.size, 7, prefix: 128)
        writer.write(encoded)
      else
        integer(string.bytesize, 7)
        writer << string
      end
    end
  end
end
