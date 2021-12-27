module HPack
  class Huffman
    class Node
      property left : Node?  # bit 0
      property right : Node? # bit 1
      property value : UInt8?

      @[AlwaysInline]
      def leaf?
        left.nil? && right.nil?
      end

      def add(binary, len, value)
        node = self

        (len - 1).downto(0) do |i|
          if binary.bit(i) == 1
            node = (node.right ||= Node.new)
          else
            node = (node.left ||= Node.new)
          end
        end

        node.value = value
        node
      end
    end
  end
end
