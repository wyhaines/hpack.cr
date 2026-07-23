# Default suite:
#
#   crystal run -p -s -t --release benchmark.cr
#
# Extended corpus, table depths, and input sizes:
#
#   HPACK_BENCH_EXTENDED=1 crystal run -p -s -t --release benchmark.cr
#
# Extended suite with the concurrent Huffman report:
#
#   HPACK_BENCH_EXTENDED=1 crystal run -Dpreview_mt -p -s -t --release benchmark.cr

require "./benchmarks/suite"

HPackBench.run
