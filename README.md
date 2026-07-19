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

## Codable

`MessagePackEncoder` / `MessagePackDecoder` mirror `JSONEncoder` / `JSONDecoder`:

```swift
struct Person: Codable {
    var id: Int
    var name: String
    var tags: [String]
}

let data = try MessagePackEncoder().encode(Person(id: 1, name: "Alice", tags: ["a"]))
let person = try MessagePackDecoder().decode(Person.self, from: data)
```

- Keyed containers become maps with string keys; maps with integer wire keys
  can be decoded through `CodingKey.intValue`.
- `Date` ↔ the spec's timestamp extension (ext type -1; numeric seconds are
  also accepted when decoding), `Data` ↔ bin 8/16/32, and
  `MessagePackTimestamp` ↔ ext type -1.
- Integers encode with the smallest wire format and decode from any integer
  format that fits the requested type.
- Encoder output is byte-identical to `MessagePackSerializer.serialize` of
  the equivalent value tree (smallest headers everywhere).

### Codable performance

Neither direction materializes a `MessagePackValue` tree:

- **Encoding** streams bytes into a growable buffer in a single pass.
  Container headers (counts unknown up front) are reserved at full width,
  counts are accumulated in the reserved bytes themselves, and headers are
  compacted to the smallest format in one final pass.
- **Decoding** walks the raw bytes directly. A keyed container scans its
  entries' byte offsets once and matches coding keys by comparing UTF-8
  bytes in place (no key `String` allocations), starting each lookup at the
  previous match so keys requested in wire order cost O(1). Container scans
  are memoized so a decoded value is never skipped twice.
- Hot paths avoid allocation: index coding keys build their `stringValue`
  lazily, decode primitives report failures via typed throws and attach
  coding-path context only when an error actually propagates, and the
  encoder's buffer sits behind a pointer to bypass dynamic exclusivity
  checks.

p50 wall clock, same machine as below, 1k-element array of a 6-field struct:

| Workload | MessagePackEncoder/Decoder | Foundation JSONEncoder/Decoder |
|---|---|---|
| encode structs (1k) | 784 µs | 1.69 ms |
| decode structs (1k) | 1.58 ms | 2.30 ms |
| encode int array (10k) | 1.19 ms | — |
| decode int array (10k) | 1.61 ms | — |

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

102 tests cover every format's byte-level encoding, boundary values (fixint/str/bin/array/map size class edges), Unicode, error paths (truncation, reserved bytes, invalid UTF-8, trailing bytes, depth limit), round-trip fidelity, and the Codable layer (scalar extremes, nested/optional/enum/dictionary round trips, serializer interop, class inheritance via `superEncoder`, manual keyed/unkeyed/nested containers, and decoding errors).
