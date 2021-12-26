module HPack
  @[Flags]
  enum Indexing : UInt8
    INDEXED = 128_u8
    ALWAYS  =  64_u8
    NEVER   =  16_u8
    NONE    =   0_u8
  end
end
