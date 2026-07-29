# Changelog

All notable changes to this project are documented in this file.

## [1.4.0] - 2026-07-28

### Performance

The encode and decode paths were reworked for speed and lower allocation.
The public API is unchanged.

- The dynamic table now keeps a small hash index alongside its ring
  buffer, so encoder lookups only fall back to a linear scan for the
  oldest entries instead of every miss. Paired same-session benchmarks
  measured roughly +13% on encode from this change alone.
- Huffman string encoding is now single-pass into a reusable scratch
  buffer, replacing a two-pass length-then-encode approach: roughly
  +14.9% on encode in paired benchmarks.
- Huffman literal decoding now writes directly into a pointer-addressed
  destination instead of through an intermediate buffer: roughly +43.3%
  on that decode path.
- Varint decoding uses shifts instead of exponentiation: roughly +4.5%
  on decode.
- `#encode_into` now encodes into a concrete `IO::Memory` buffer and
  copies out once, instead of writing through a polymorphic `IO`:
  roughly +3.4% on encode.

Measured with the bundled `benchmarks/hpack_bench.cr` harness (a 9-field
mixed static/dynamic-table request block, `--release`): decoder
allocation dropped from 880 to 832 bytes per operation (-5.5%); encoder
allocation is unchanged at 496 bytes per operation. End-to-end
throughput numbers from this benchmark were collected on a busy shared
machine and came out noisier, run to run, than the itemized deltas
above, so treat those isolated, paired measurements as the more
reliable signal for what to expect.

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
