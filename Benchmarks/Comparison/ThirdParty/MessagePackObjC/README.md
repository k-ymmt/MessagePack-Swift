# MessagePackObjC (vendored)

Vendored copy of [msgpack/msgpack-objectivec](https://github.com/msgpack/msgpack-objectivec)
at commit `03ae6049a627815170bbc42ebc8ba6452be563f9`, used only by the
`ComparisonBenchmarks` package. The upstream repository has no SwiftPM
manifest, so the sources are wrapped in an SPM Objective-C target here.

The bundled `msgpack_src` C implementation is from the original msgpack-c
project (Copyright FURUHASHI Sadayuki, Apache License 2.0); license headers are
kept intact in each file.

Local patches against upstream:

- Dropped `MessagePackParser+Streaming.{h,m}` and the `msgpack_unpacker` ivar it
  needed, so the public headers (in `include/`) are Foundation-only and safe for
  SPM's generated module map. `MessagePackParser.m` now includes
  `msgpack_src/msgpack.h` itself.
- `MessagePack.h` no longer imports the removed streaming header.
- `MessagePackPacker.m`: `(CFNumberRef)num` → `(__bridge CFNumberRef)num` for
  ARC (SPM compiles Objective-C with ARC; the upstream code already guards its
  manual `release`/`autorelease` calls with `__has_feature(objc_arc)`).

Note: this library implements the pre-2013 MessagePack spec (raw family only —
no str8/bin/ext), so benchmarks always round-trip data it produced itself.
