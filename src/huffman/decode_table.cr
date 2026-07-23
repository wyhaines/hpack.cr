module HPack
  class Huffman
    private NO_VALUE         = UInt16::MAX
    private EOS_VALUE        = 256_u16
    private EOS_CODE         = (1_u32 << 30) - 1
    private EOS_LENGTH       = 30_u8
    private INVALID          =  1_u8
    private ACCEPTING        =  2_u8
    private PADDING_TOO_LONG =  4_u8

    private struct DecodeTransition
      getter next_state : UInt16
      getter first_value : UInt16
      getter second_value : UInt16
      getter flags : UInt8

      def initialize(@next_state, @first_value, @second_value, @flags)
      end

      @[AlwaysInline]
      def invalid? : Bool
        flags & INVALID != 0
      end

      @[AlwaysInline]
      def accepting? : Bool
        flags & ACCEPTING != 0
      end

      @[AlwaysInline]
      def padding_too_long? : Bool
        flags & PADDING_TOO_LONG != 0
      end
    end

    private class BuildNode
      property left : BuildNode?
      property right : BuildNode?
      property value = NO_VALUE
      property state = 0_u16
      getter depth : UInt8
      getter? eos_prefix : Bool

      def initialize(@depth = 0_u8, @eos_prefix = true)
      end
    end

    private def build_decode_table : Slice(DecodeTransition)
      root = BuildNode.new
      table.each do |value, code, length|
        add_code(root, code, length, value.to_u16)
      end
      add_code(root, EOS_CODE, EOS_LENGTH, EOS_VALUE)

      states = [] of BuildNode
      collect_states(root, states)
      if states.size > UInt16::MAX
        raise ArgumentError.new("Huffman table has too many decode states")
      end
      states.each_with_index do |state, index|
        state.state = index.to_u16
      end

      Slice(DecodeTransition).new(states.size * 256, read_only: true) do |index|
        state = states[index // 256]
        byte = (index % 256).to_u8
        build_transition(root, state, byte)
      end
    end

    private def add_code(root : BuildNode, code : UInt32, length : UInt8, value : UInt16)
      node = root

      (length - 1).downto(0) do |bit_index|
        if node.value != NO_VALUE
          raise ArgumentError.new("Huffman code extends an existing symbol")
        end

        bit = code.bit(bit_index)
        child = bit == 1 ? node.right : node.left
        unless child
          child = BuildNode.new(node.depth + 1, node.eos_prefix? && bit == 1)
          if bit == 1
            node.right = child
          else
            node.left = child
          end
        end
        node = child
      end

      if node.value != NO_VALUE || node.left || node.right
        raise ArgumentError.new("duplicate or prefix Huffman code")
      end
      node.value = value
    end

    private def collect_states(node : BuildNode, states : Array(BuildNode))
      return unless node.value == NO_VALUE

      states << node
      if left = node.left
        collect_states(left, states)
      end
      if right = node.right
        collect_states(right, states)
      end
    end

    private def build_transition(root : BuildNode, start : BuildNode, byte : UInt8) : DecodeTransition
      node = start
      first_value = NO_VALUE
      second_value = NO_VALUE

      7.downto(0) do |bit_index|
        node = (byte.bit(bit_index) == 1 ? node.right : node.left) ||
               return DecodeTransition.new(0_u16, first_value, second_value, INVALID)

        if node.value != NO_VALUE
          if node.value == EOS_VALUE
            return DecodeTransition.new(0_u16, first_value, second_value, INVALID)
          elsif first_value == NO_VALUE
            first_value = node.value
          elsif second_value == NO_VALUE
            second_value = node.value
          else
            raise ArgumentError.new("Huffman table emits more than two symbols per byte")
          end
          node = root
        end
      end

      DecodeTransition.new(node.state, first_value, second_value, terminal_flags(node))
    end

    private def terminal_flags(node : BuildNode) : UInt8
      if node.depth == 0 || (node.eos_prefix? && node.depth <= 7)
        ACCEPTING
      elsif node.eos_prefix?
        PADDING_TOO_LONG
      else
        0_u8
      end
    end
  end
end
