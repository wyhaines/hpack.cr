module HPack
  # The DynamicTable is a table of header names and values. It is implemented as a
  # subclass of a Deque in order to get access to all of the iteration and interrogation
  # methods without having to write methods which explicitly wrap them. Fewer lines to
  # maintain is a win. As a caveat, though, do not interact with the storage or deletion
  # of data via any methods other than `#add`, `#clear`, `#find_index`, `#find_name_index`,
  # and `#rebuild_index`, as the native `Deque` methods will not keep an accurate tally of
  # the bytesize of the structure nor of the hash indexes used for O(1) lookup.
  #
  # `#eviction_listener`, `#drop_newest`, `#restore_evicted`, and
  # `#restore_insert_count` (each marked `:nodoc:`) are public only because
  # `Encoder#with_writer`'s transactional rollback is a different class and
  # needs to call them; they exist solely to support that rollback and are
  # not part of this class's supported API otherwise.
  class DynamicTable < Deque(Tuple(String, String))
    getter bytesize : Int32 = 0
    property maximum : Int32 = 4096

    # Monotonically increasing insertion sequence number. The newest entry
    # always has seq == @insert_count; an entry with seq `s` has relative
    # index `@insert_count - s + 1` (1 = newest).
    @insert_count = 0_u64
    @entry_seq = Hash(Tuple(String, String), UInt64).new
    @name_seq = Hash(String, UInt64).new

    # :nodoc:
    #
    # Invoked once per entry evicted by `cleanup`, in oldest-to-newest
    # eviction order. Set only during a transactional encode (see
    # `Encoder#with_writer`); used to journal evictions for rollback
    # instead of snapshotting the whole table up front.
    property eviction_listener : Proc(Tuple(String, String), Nil)?

    def initialize(@maximum = 4096)
      super()
    end

    # Current insertion sequence counter. Exposed only for transactional
    # rollback: some insertions made during a failed transaction may have
    # already been evicted (and are therefore invisible to `drop_newest`),
    # so the counter cannot always be recovered purely by counting
    # `drop_newest` calls; rollback instead restores it directly from a
    # value captured at transaction start.
    def insert_count : UInt64
      @insert_count
    end

    def add(name, value)
      header = {name, value}
      unshift header
      @bytesize += count(header)
      seq = (@insert_count += 1)
      @entry_seq[header] = seq
      @name_seq[name] = seq
      cleanup
    end

    # Returns the 1-based relative index (1 = newest) of the entry whose
    # name and value match exactly, or nil if absent.
    def find_index(name : String, value : String) : Int32?
      if seq = @entry_seq[{name, value}]?
        (@insert_count - seq).to_i32 + 1
      end
    end

    # Returns the 1-based relative index (1 = newest) of the most recent
    # entry whose name matches, or nil if absent.
    def find_name_index(name : String) : Int32?
      if seq = @name_seq[name]?
        (@insert_count - seq).to_i32 + 1
      end
    end

    def clear
      @bytesize = 0
      @entry_seq.clear
      @name_seq.clear
      super
    end

    # Rebuilds both hash indexes from current contents. Used only on
    # transactional rollback (rare path).
    def rebuild_index : Nil
      @entry_seq.clear
      @name_seq.clear
      (size - 1).downto(0) do |i| # oldest -> newest so newest wins
        header = self[i]
        seq = @insert_count - i
        @entry_seq[header] = seq
        @name_seq[header[0]] = seq
      end
    end

    # Changes this table's local capacity and evicts entries as needed.
    #
    # Encoder users applying a negotiated capacity change should call
    # `Encoder#resize_table` instead so the peer receives the required HPACK
    # dynamic-table size update.
    def resize(@maximum)
      cleanup
    end

    private def cleanup
      while bytesize > maximum
        evicted_seq = @insert_count - size + 1 # oldest live entry's seq
        header = pop
        @bytesize -= count(header)
        @entry_seq.delete(header) if @entry_seq[header]? == evicted_seq
        @name_seq.delete(header[0]) if @name_seq[header[0]]? == evicted_seq
        @eviction_listener.try &.call(header)
      end
    end

    # :nodoc:
    #
    # Removes the newest entry. Used only to undo an insertion that is
    # still present in the table during transactional rollback (an
    # insertion evicted earlier in the same transaction is instead simply
    # absent from the journal replay — see `Encoder#rollback_table`).
    def drop_newest : Nil
      header = shift
      @bytesize -= count(header)
      @insert_count -= 1
    end

    # :nodoc:
    #
    # Re-inserts a previously evicted entry at the old (oldest) end,
    # restoring original order relative to whatever survived the
    # transaction. Does not touch `@insert_count` or the hash indexes:
    # the entry regains a coherent seq only once `rebuild_index` recomputes
    # every entry's seq from its restored position and the (separately
    # restored) insertion counter.
    def restore_evicted(header : Tuple(String, String)) : Nil
      push header
      @bytesize += count(header)
    end

    # :nodoc:
    #
    # Directly restores the insertion sequence counter to a previously
    # captured value. See `#insert_count` for why this can't always be
    # derived from counting `drop_newest` calls.
    def restore_insert_count(value : UInt64) : Nil
      @insert_count = value
    end

    @[AlwaysInline]
    private def count(header)
      header[0].bytesize + header[1].bytesize + 32
    end
  end
end
