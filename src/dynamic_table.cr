module HPack

  # The DynamicTable is a table of header names and values. It is implemented as a
  # subclass of a Deque in order to get access to all of the iteration and interrogation
  # methods without having to write methods which explicitly wrap them. Fewer lines to
  # maintain is a win. As a caveat, though, do not interact with the storage or deletion
  # of data via any methods other than `#add` and `#clear`, as the native `Deque` methods
  # will not keep an accurate tally of the bytesize of the structure.
  class DynamicTable < Deque(Tuple(String, String))
    getter bytesize : Int32 = 0
    property maximum : Int32 = 4096

    def initialize(@maximum = 4096)
      super()
    end

    def add(name, value)
      header = {name, value}
      self.unshift header
      @bytesize += count(header)
      cleanup
    end

    def clear
      @bytesize = 0
      super
    end

    def resize(@maximum)
      cleanup
    end

    @[AlwaysInline]
    private def cleanup
      while bytesize > maximum
        @bytesize -= count(pop)
      end
    end

    @[AlwaysInline]
    private def count(header)
      header[0].bytesize + header[1].bytesize + 32
    end
  end
end
