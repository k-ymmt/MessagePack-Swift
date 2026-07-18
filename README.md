# MessagePackSwift

A high-performance [MessagePack](https://github.com/msgpack/msgpack/blob/master/spec.md) serializer/deserializer for Swift.

## Usage

```swift
import MessagePackSwift

let value = MessagePackValue.map([
    .string("name"): .string("MessagePackSwift"),
    .string("version"): .array([.uint8(1), .uint8(0), .uint8(0)]),
])

let data = try MessagePackSerializer.serialize(value: value)
let decoded = try MessagePackSerializer.deserialize(data: data)
```

Both APIs use typed throws (`throws(MessagePackError)`).

## Design notes

- **Spec compliance**: All format families are supported (fixint, fixmap, fixarray, fixstr, nil, bool, bin 8/16/32, ext 8/16/32, float 32/64, uint/int 8–64, fixext 1–16, str 8/16/32, array 16/32, map 16/32). The reserved byte `0xc1` and invalid UTF-8 in strings are rejected. Timestamps round-trip through `.ext(type: -1, ...)`.
- **Smallest representation**: As recommended by the spec, integers serialize with the smallest format that represents the value, regardless of the case width (`.int64(5)` encodes as a 1-byte positive fixint). Consequently, deserialization maps each wire format to the narrowest matching case (positive fixint → `.uint8`, negative fixint → `.int8`, `uint 16` → `.uint16`, …); use the `int64Value` / `uint64Value` accessors for width-agnostic reads.
- **Iterative, not recursive**: Both directions use explicit frame stacks, so deeply nested input can never overflow the call stack. Deserialization enforces a nesting-depth limit (512) as DoS protection; serialization has no depth limit.
- **Two-pass serialization**: An exact size pass followed by direct writes into a single exactly-sized buffer — no growth reallocations, and the result is handed to `Data` without copying.
- **Zero-copy parsing**: The parser walks the raw bytes with unaligned big-endian loads; strings are built via `UTF8Span` (validate once, no revalidation) on OS 26+, falling back to `String(validating:)`.
- **Hostile input**: Length claims are checked against remaining input before allocating, so truncated or malicious headers (e.g. "4 GB string follows") fail fast without large allocations.

## Benchmarks

Uses [ordo-one/package-benchmark](https://github.com/ordo-one/package-benchmark):

```sh
brew install jemalloc   # once
swift package --allow-writing-to-package-directory benchmark
```

Results on an Apple Silicon MacBook (arm64, Swift 6.4, release), p50 wall clock:

| Workload | serialize | deserialize |
|---|---|---|
| small int array (64) | 750 ns | 625 ns |
| large int array (10k) | 65 µs | 80 µs |
| double array (10k) | 63 µs | 82 µs |
| string array (1k) | 18 µs | 64 µs |
| map (1k entries) | 55 µs | 74 µs |
| nested objects (500) | 212 µs | 283 µs |
| binary 1 MB | 16 µs | 16 µs |

Serialization performs 4 allocations total for flat payloads of any size (size-pass stack, write-pass stack, output buffer, `Data` wrapper); deserialization of scalar arrays performs 2.

## Testing

```sh
swift test
```

46 tests cover every format's byte-level encoding, boundary values (fixint/str/bin/array/map size class edges), Unicode, error paths (truncation, reserved bytes, invalid UTF-8, trailing bytes, depth limit), and round-trip fidelity.
