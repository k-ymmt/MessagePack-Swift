# MPMessagePack (vendored)

Vendored copy of [gabriel/MPMessagePack](https://github.com/gabriel/MPMessagePack)
at commit `5e61d2a98fc548101eafd1934a6b09261184db1c` (v1.5.2), used only by the
`ComparisonBenchmarks` package. Upstream ships a podspec and a Carthage file but
no SwiftPM manifest, so the sources are wrapped in an SPM Objective-C target
here. MIT licensed; `LICENSE` is copied verbatim.

Serialization is backed by the bundled [cmp](https://github.com/camgunz/cmp)
C implementation (`cmp.c`/`cmp.h`), which covers the current MessagePack spec.

The sources themselves are **unmodified**. Upstream already guards its
GHODictionary import with `#if SWIFT_PACKAGE`, which SPM defines, so
GHODictionary is declared as a normal package dependency instead of being
vendored too.

Only the core packer/parser is vendored. Omitted from upstream's
`MPMessagePack/` directory:

- `RPC/` and `include/RPC/` — MessagePack-RPC client/server.
- `XPC/` and `include/XPC/` — XPC service plumbing (upstream's podspec already
  excludes these on iOS/tvOS).
- `MPMessagePack.h` — the framework umbrella header, which imports the RPC and
  XPC headers above. SPM generates its own module map from `include/`, so it is
  not needed.
