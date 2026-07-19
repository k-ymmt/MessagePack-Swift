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
  `MessagePackTimestamp` ↔ ext type -1. Dates that cannot be represented as
  a timestamp (non-finite, out of `Int64` seconds range) throw
  `EncodingError.invalidValue`.
- Integers encode with the smallest wire format and decode from any integer
  format that fits the requested type; out-of-range numbers (including
  float64 → `Float` overflow) throw instead of truncating.
- Encoder output is byte-identical to `MessagePackSerializer.serialize` of
  the equivalent value tree (smallest headers everywhere).
- Both coders are `Sendable` (unchecked, value-semantic — like
  `JSONEncoder`, values placed in `userInfo` must be `Sendable` for
  cross-task use).
- Codable edge cases behave like `JSONEncoder`/`JSONDecoder`: repeated
  `container(keyedBy:)` requests merge into one map, a `superEncoder()`
  that is never used contributes nothing (its entry is written lazily on
  first use), `superDecoder()` for a missing key decodes as nil, and a
  value that encodes nothing throws. Because encoding is streaming, writes
  must be well nested — out-of-order writes to an already-closed container
  trap with a precondition failure instead of corrupting output. Decoding
  enforces a nesting-depth limit (128) against hostile input driving
  recursive `Decodable` types.

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
- Values of natively represented types (integers, strings, floats, bools,
  `Date`/`Data`/timestamps) flowing through the generic
  `encode<T>`/`decode<T>` funnels are coded directly, bypassing the
  per-value `Encodable`/`Decodable` container machinery — `[Int]` and
  `[String]` code at a handful of allocations total instead of one per
  element.
- Hot paths avoid allocation: index coding keys build their `stringValue`
  lazily, coding paths are only materialized for errors and nested
  containers, decode primitives report failures via typed throws and attach
  coding-path context only when an error actually propagates, and the
  encoder's buffer sits behind a pointer to bypass dynamic exclusivity
  checks.

p50 wall clock, same machine as below, 1k-element array of a 6-field struct:

| Workload | MessagePackEncoder/Decoder | Foundation JSONEncoder/Decoder |
|---|---|---|
| encode structs (1k) | 607 µs | 1.67 ms |
| decode structs (1k) | 1.25 ms | 2.19 ms |
| encode int array (10k) | 244 µs | — |
| decode int array (10k) | 490 µs | — |

## Macro: `@MessagePackSerializable`

The fastest route. The macro generates a `MessagePackSerializable` conformance
at compile time — direct wire-format reads/writes with no `Codable` container
machinery, no intermediate `MessagePackValue` tree, and no runtime reflection:

```swift
@MessagePackSerializable
struct Foo {
    let bar: Int
    let hoge: String
}

let foo = Foo(bar: 0, hoge: "")
let serialized: Data = MessagePackSerializer.serialize(foo)
let deserialized: Foo = try MessagePackSerializer.deserialize(Foo.self, from: serialized)
```

- Structs are serialized as maps keyed by property name, in declaration
  order — byte-identical to what the `Codable` route produces for an
  equivalent type, with one exception: a `nil` optional is written as an
  explicit MessagePack nil, where `Codable` synthesis (`encodeIfPresent`)
  omits the key. Either route decodes the other's output correctly, so they
  still interoperate freely.
- Decoding accepts fields in any order, skips unknown keys, throws
  `MessagePackError.missingField` for absent required fields, and uses the
  property's default value (or `nil` for optionals) when a field is absent.
  Field names are matched against the wire keys by raw byte comparison
  (`MessagePackReader.readKey(matchedBy:)`), so no key `String` is ever
  materialized; unknown keys are still UTF-8-validated before being
  skipped.
  Container nesting is limited to 128 levels (like the `Codable` route), so
  hostile input cannot drive unbounded recursion through recursively
  defined types.
- `@MessagePackKey("wire_name")` renames a field on the wire;
  `@MessagePackIgnored` excludes a stored property (the macro requires it
  to have a default value or be an optional `var`). Duplicate wire keys are
  rejected at compile time. Computed, `static`, and `lazy` properties are
  ignored; `let` properties with an initial value are written but not read
  back, matching `Codable` synthesis.
- Supported field types out of the box: `Bool`, all fixed-width integers,
  `Float`/`Double`, `String`, `Data` (bin), `Date` /
  `MessagePackTimestamp` (timestamp ext -1), `Optional`, `Array`, `Set`,
  `Dictionary` (any serializable key type, e.g. `Int` keys), nested
  `@MessagePackSerializable` types, generic structs (parameters are
  constrained automatically), and `MessagePackValue` for dynamically shaped
  fields.
- Enums with a raw value need no macro — declaring the conformance is
  enough (`enum Color: String, MessagePackSerializable`); a default
  implementation is provided for `RawRepresentable` types.
- Custom conformances can be written by hand against the public
  `MessagePackWriter` / `MessagePackReader` primitives. Both are
  noncopyable (`~Copyable`) — they own or borrow raw memory, so a copy
  escaping a conformance would be unsound, and the compiler now rejects it.
  When reading containers manually, balance each header read with
  `endContainer()`.
- `serialize` is non-throwing (single pass into a growable buffer, handed
  to `Data` without copying); unrepresentable values (strings/containers
  over MessagePack's 2^32-1 limits, dates outside the timestamp range) stop
  with a precondition failure, unlike the throwing `serialize(value:)` /
  `MessagePackEncoder` routes. `deserialize` uses typed throws
  (`throws(MessagePackError)`) and validates length claims against the
  remaining input before allocating.

p50 wall clock, same fixtures as the Codable table:

| Workload | macro | Codable (MessagePack) | serializer route | JSON |
|---|---|---|---|---|
| serialize structs (1k) | 66 µs | 607 µs | 1.07 ms | 1.67 ms |
| deserialize structs (1k) | 225 µs | 1.25 ms | 1.06 ms | 2.19 ms |
| round trip structs (1k) | 292 µs | 1.85 ms | — | — |
| serialize int array (10k) | 28 µs | 244 µs | — | — |
| deserialize int array (10k) | 23 µs | 490 µs | — | — |

## Design notes

- **Spec compliance**: All format families are supported (fixint, fixmap, fixarray, fixstr, nil, bool, bin 8/16/32, ext 8/16/32, float 32/64, uint/int 8–64, fixext 1–16, str 8/16/32, array 16/32, map 16/32). The reserved byte `0xc1` and invalid UTF-8 in strings are rejected. Timestamps round-trip through `.ext(type: -1, ...)`.
- **Smallest representation**: As recommended by the spec, integers serialize with the smallest format that represents the value, regardless of the case width (`.int64(5)` encodes as a 1-byte positive fixint). Consequently, deserialization maps each wire format to the narrowest matching case (positive fixint → `.uint8`, negative fixint → `.int8`, `uint 16` → `.uint16`, …); use the `int64Value` / `uint64Value` accessors for width-agnostic reads.
- **Iterative, not recursive**: Both directions use explicit frame stacks, so deeply nested input can never overflow the call stack. Deserialization enforces a nesting-depth limit (512) as DoS protection; serialization has no depth limit.
- **Two-pass serialization**: An exact size pass followed by direct writes into a single exactly-sized buffer — no growth reallocations, and the result is handed to `Data` without copying.
- **Zero-copy parsing**: The parser walks the raw bytes with unaligned big-endian loads; strings are built via `UTF8Span` (validate once, no revalidation) on OS 26+, falling back to `String(validating:)`. The availability check is resolved once per process, not per string.
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
| large int array (10k) | 67 µs | 80 µs |
| double array (10k) | 65 µs | 80 µs |
| string array (1k) | 18 µs | 59 µs |
| map (1k entries) | 54 µs | 70 µs |
| nested objects (500) | 208 µs | 275 µs |
| binary 1 MB | 16 µs | 16 µs |

Serialization performs 4 allocations total for flat payloads of any size (size-pass stack, write-pass stack, output buffer, `Data` wrapper); deserialization of scalar arrays performs 2.

## Testing

```sh
swift test
```

191 tests cover every format's byte-level encoding, boundary values (fixint/str/bin/array/map size class edges), Unicode, error paths (truncation, reserved bytes, invalid UTF-8, trailing bytes, depth limit), round-trip fidelity, the Codable layer (scalar extremes, nested/optional/enum/dictionary round trips, serializer interop, class inheritance via `superEncoder`, manual keyed/unkeyed/nested containers, and decoding errors), and the macro layer (expansion snapshots, round trips for every supported field type, wire-format details, decoding robustness against reordered/unknown/duplicate/hostile input, and byte-for-byte Codable interop).
