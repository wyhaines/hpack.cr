# Benchmark Baseline

Recorded on 2026-07-23 with Crystal 1.21.0-dev (`edd8336a2`) on an
AMD Ryzen 9 7940HS (8 cores/16 threads), x86_64 Linux. The repository base
revision was `a2f3002`; the working tree included the completed correctness,
Huffman, and encoder-allocation changes.

Command:

```sh
CRYSTAL_CACHE_DIR=/tmp/crystal-cache-hpack \
  crystal run -p -s -t --release benchmark.cr
```

The default harness used 250 ms of warmup and 500 ms of calculation per case.
Untimed validation passed before measurement.

```text
Huffman
encode/short ASCII                 55.14M   18.13ns    16B/op
decode/short ASCII                 31.88M   31.36ns    32B/op
encode/HTTP value                   8.72M  114.63ns    48B/op
decode/HTTP value                   5.02M  199.33ns    80B/op
encode/long ASCII                 486.19k    2.06us   800B/op
decode/long ASCII                 294.56k    3.39us  1.31kB/op
encode/all byte values              1.30M  770.71ns   672B/op
decode/all byte values            544.38k    1.84us   272B/op
encode/expanding input             84.40M   11.85ns    16B/op
decode/expanding input             54.50M   18.35ns    16B/op

Encoder
cold literal/NONE/raw/owned         3.83M  260.85ns   624B/op
cold literal/NONE/Huffman/owned     2.67M  375.05ns   528B/op
cold literal/ALWAYS/raw/owned       3.69M  270.74ns   704B/op
cold literal/ALWAYS/Huffman/owned   2.60M  384.15ns   608B/op
cold literal/NEVER/raw/owned        4.04M  247.48ns   624B/op
cold literal/NEVER/Huffman/owned    2.73M  366.17ns   528B/op
warm raw/lowercase name             6.66M  150.13ns    80B/op
warm raw/mixed-case name            6.26M  159.68ns   112B/op
warm raw/multiple values            3.51M  284.95ns    64B/op
warm raw/owned output               2.26M  442.51ns   432B/op
warm raw/caller buffer reset        2.47M  405.61ns   288B/op
warm fields/raw/owned output        3.32M  300.80ns   144B/op
warm fields/raw/caller buffer       3.54M  282.46ns     0B/op
warm exact dynamic/Huffman          2.81M  355.34ns   304B/op

Decoder
warm/static-only                    9.35M  107.00ns   224B/op
warm/literal raw                   13.00M   76.93ns   256B/op
warm/literal Huffman                2.87M  348.03ns   336B/op
reset/RFC dynamic sequence          1.32M  755.76ns  1.19kB/op
cold/table-size update             10.23M   97.75ns   448B/op
warm/metadata                       7.87M  127.14ns   368B/op
warm/static/caller headers          9.64M  103.75ns   224B/op
cold/small-table sequence           1.23M  811.34ns  2.55kB/op

Lookup
static exact                       331.55M    3.02ns     0B/op
default table/dynamic newest        18.18M   55.02ns     0B/op
default table/dynamic middle        17.40M   57.48ns     0B/op
default table/dynamic oldest        13.07M   76.53ns     0B/op
default table/unknown-name miss     13.30M   75.17ns     0B/op
default table/repeated-name new     14.65M   68.24ns     0B/op
small table/oldest retained         18.04M   55.42ns     0B/op
```

Huffman decode rows were rerun with the same settings after the final
fiber-local scratch-buffer refinement; the other rows are from the initial
full-suite run.

For a same-session pre-performance reference, the former two-report harness
measured its warmed encoder at 1.86M ops/s, 536.29 ns/op, 784 B/op and its
three-block decoder at 1.05M ops/s, 954.00 ns/op, 1.19 kB/op. Those combined
workloads are not directly comparable to most focused cases above.

## Dynamic-Table Size Coordination

Recorded on 2026-07-23 after implementing negotiated encoder resizing and
decoder limit synchronization:

```text
encoder/warm/table resize/caller buffer   67.78M   14.75ns     0B/op
```

Untimed validation first confirmed the exact two-update prefix and matching
encoder/decoder capacities. A same-session release comparison against the
clean `a909c58` revision showed identical allocation counts in every decoder
case and no consistent timing regression. Representative control-to-current
results were:

```text
warm/static-only                   122.88ns -> 118.65ns
warm/literal raw                    91.42ns ->  90.61ns
reset/RFC dynamic sequence         887.22ns -> 872.93ns
cold/table-size update             122.91ns -> 123.16ns
cold/small-table sequence          869.76ns -> 884.28ns
```

These measurements document the feature cost; CI does not enforce timing
thresholds.
