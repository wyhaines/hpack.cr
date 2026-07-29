# Changelog

All notable changes to this project are documented in this file.

## [1.4.0] - 2026-07-28

### Performance

The encode and decode paths were reworked for speed and lower allocation.
The public API is unchanged. Measured via interleaved, same-machine
paired runs (alternating a 1.3.0-era baseline binary and a 1.4.0 binary,
5 pairs, medians reported) against the bundled
`benchmarks/hpack_bench.cr` harness, a 9-field mixed static/dynamic-table
request block, `--release`.

- **Decoding is faster and leaner:** 1.20M ips vs. the baseline's 1.13M
  (+6.2%), and allocation dropped from 880 to 832 bytes per operation
  (-5.5%). Contributing changes, measured in isolation: Huffman literal
  decoding through a pointer-addressed destination instead of an
  intermediate buffer (+43.3% on that path), and shift-based varint
  decoding instead of exponentiation (+4.5%).
- **Encoding did not show a net improvement on this workload:** paired
  medians came out slightly in the baseline's favor (2.17M ips vs.
  2.28M, roughly -5%), even though each encode-side change measured a
  real gain in isolation — a hash index alongside the dynamic table's
  ring buffer so lookups fall back to a linear scan only for the oldest
  entries (+13%), single-pass Huffman string encoding into a reusable
  scratch buffer instead of a two-pass length-then-encode approach
  (+14.9%), and `#encode_into` encoding into a concrete `IO::Memory`
  buffer with a single copy-out instead of writing through a
  polymorphic `IO` (+3.4%). Encoder allocation is unchanged at 496
  bytes per operation either way. This benchmark's dynamic table only
  ever holds 9 entries and settles into steady-state indexed lookups
  after warmup, which may explain why it doesn't exercise the
  encode-side hot paths (a larger, churning table; cold Huffman-heavy
  literals) the way the isolated measurements did — that hypothesis is
  unconfirmed, and the discrepancy is flagged for further investigation
  rather than smoothed over.
- Absolute throughput on both paths varies with concurrent machine
  load; interleaving the two binaries controls for that between them
  within a run, but doesn't eliminate run-to-run scatter, which is why
  results above are medians across multiple interleaved pairs rather
  than single runs.

### Changed

- `#encode_into` now fully encodes into an internal buffer before
  copying it to the destination `IO` in a single `write` call. A
  failure partway through encoding leaves the destination untouched.
  Previously, bytes could be written to the destination incrementally
  as they were produced, so a failure partway through a block could
  leave partial output behind.
- Resource-cap violation messages changed slightly: a decoded Huffman
  string over its configured cap now reports the configured cap value
  (`"decoded string exceeds the configured cap (N)"`) instead of the
  reader's remaining byte budget. If you match on these messages,
  re-check them.

### Fixed

- Guarded field-size accounting in `Decoder#decode_each` against
  `UInt64` overflow. A crafted input that repeats a 1-byte
  fully-indexed reference against a large configured dynamic-table size
  could previously overflow the running total; it now raises
  `ResourceLimitError`, consistent with every other resource-cap
  violation, instead of surfacing a bare arithmetic error.

### Internal

- Replaced per-block dynamic-table snapshotting with a mutation
  journal backing `#encode_into`'s rollback-on-failure behavior (this
  also caught and fixed a rollback bug in the snapshotting approach
  before it ever shipped).
- Removed a `Fiber` monkey-patch used for per-fiber scratch buffers,
  along with other dead internal surface (`BoundedOutput`,
  `DecodeScratch`, unused `SliceReader` methods) and roughly 100 lines
  of `preview_mt` boilerplate, now collapsed into a single
  `synchronize` helper.
- Bumped the development-only `ameba` pin to
  `crystal-ameba/ameba@34a3de4` so `bin/ameba` builds on current
  Crystal.

### Testing

- `crystal spec`: 158 examples, 0 failures.
- `crystal spec -Dpreview_mt`: 160 examples, 0 failures.
- `bin/ameba src spec`: 0 offenses.
