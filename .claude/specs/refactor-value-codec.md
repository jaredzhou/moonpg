# Spec: Refactor Value Encoding/Decoding with Codec-Based Architecture

## Problem Statement

The current encoding/decoding architecture in moonpg has several fundamental issues:

1. **`RawValue` is an unnecessary intermediate type.** User types convert to `Value`, then `Value` converts to `RawValue` (carrying `Format` + `Bytes`), then `RawValue` converts back to user types. This double-indirection adds complexity without benefit — the format and OID information is already available from `RowDescription`/`ParameterDescription` on the wire.

2. **Each type encodes itself, with no central codec registry.** The `ToValue::to_raw_value()` default implementation calls `default_encode()`, which encodes all types in text format (except `Bytes`). There is no OID-based dispatch — the encoding logic is scattered across `Value::to_raw()` helper methods, not organized by PostgreSQL type.

3. **`pg_type` (Type, TypeMap, OID constants) lives inside `wire/`**, but it should be an independent package so that the encoding/decoding layer can depend on it without creating circular dependencies.

4. **No `Codec` abstraction.** PostgreSQL has 90+ types, each with text and binary wire representations. A `Codec` trait would unify encode/decode per PG type, enable OID-based dispatch, and allow multiple OIDs to share the same codec implementation.

## Solution

Replace the `RawValue`-based architecture with a `Codec`-based architecture organized into two new packages:

- **`value/`** — Pure data layer: `Value` enum, `Format` enum, `ToValue` trait, `FromValue` trait. No wire encoding knowledge.
- **`pgtype/`** — Type system + codec layer: `Type` struct (with `Codec` field), `TypeMap` with OID→codec dispatch, `Codec` trait, concrete codec implementations, and low-level encode/decode helpers.

The data flow becomes:

```
Encode: UserType ──ToValue──▶ Value ──codec.encode(oid, format, value)──▶ Bytes
                            (oid from ParameterDescription via Describe)

Decode: Bytes ──codec.decode(oid, format, bytes)──▶ Value ──FromValue──▶ UserType
               (oid + format from FieldDescription via RowDescription)
```

`Value` carries no OID or type tag — the OID is always provided by the caller (from wire metadata).

## User Stories

1. As a moonpg user, I want a single, clear trait (`ToValue`) to convert my types into database parameters, so that I don't need to understand `RawValue` or encoding internals.

2. As a moonpg user, I want a single, clear trait (`FromValue`) to decode query results into my types, so that I don't need to handle `RawValue` or format codes manually.

3. As a moonpg user, I want parameter encoding to use the OID returned by the server's `ParameterDescription`, so that my values are encoded correctly regardless of what PG type the server infers.

4. As a moonpg user, I want result decoding to use the OID and format from `RowDescription`, so that binary and text results are both handled correctly.

5. As a moonpg user, I want `Value::Timestamp(Int64)` to represent `timestamp`/`timestamptz` columns, so that I can distinguish timestamps from raw integers.

6. As a moonpg user, I want `Value::Json(Json)` to represent `json`/`jsonb` columns, so that I can work with JSON data using MoonBit's built-in `Json` type.

7. As a moonpg user, I want unknown OIDs to fall back to text encoding, so that custom PostgreSQL types don't cause hard errors.

8. As a library maintainer, I want `pgtype` as an independent package, so that the type system and codecs can be tested in isolation without depending on wire protocol or connection logic.

9. As a library maintainer, I want a `Codec` trait with `encode`, `decode`, and `prefer_format` methods, so that each PostgreSQL type can implement its own wire encoding consistently.

10. As a library maintainer, I want multiple OIDs to share the same codec implementation (e.g., `int2`/`int4`/`int8` all use integer codecs), so that I don't duplicate encoding logic for similar types.

11. As a library maintainer, I want the `Type` struct to carry a `&Codec` field, so that OID→codec lookup is O(1) through the existing `TypeMap`.

## Implementation Decisions

### Package restructure

Three new packages replace the current flat structure:

- **`value/`** — Zero internal dependencies. Contains: `Value` enum, `Format` enum, `ToValue` trait (single method `to_value`), `FromValue` trait (single method `from_value`).
- **`pgtype/`** — Depends on `value/`. Contains: `Type` struct, `TypeMap` struct, OID constants, `Codec` trait, concrete codec structs, encode/decode helper functions, `default_map` with all registered types.
- **Root package** — Depends on `pgtype/`, `wire/`, `value/`. Contains: `Connection`, `Row`, `Pool`, `DbTx`, `ToValue`/`FromValue` impls for built-in types.

Dependency chain: `value` ← `pgtype` ← `wire` ← `root`. No cycles.

### `Value` enum (in `value/`)

Expanded from 7 to 9 variants. Variants `Timestamp` and `Json` are added for common PG types. No OID or type tag is carried — `Value` is pure data.

```moonbit
pub enum Value {
  Null
  Bool(Bool)
  Int(Int)           // int2, int4
  Int64(Int64)       // int8
  Float(Double)      // float4, float8
  String(String)     // text, varchar, bpchar, name, uuid, numeric, ...
  Bytes(Bytes)       // bytea
  Timestamp(Int64)   // timestamp, timestamptz (microseconds since Unix epoch)
  Json(Json)         // json, jsonb (MoonBit built-in Json type)
}
```

### `ToValue` trait (in `value/`)

Single method, no default implementations, no `pg_type()` method. The parameter OID comes from the server's `ParameterDescription`, not from the user type.

```moonbit
pub(open) trait ToValue {
  to_value(Self) -> Value
}
```

### `FromValue` trait (in `value/`)

Single method. Implementations decide whether to be strict (reject mismatched variants) or lenient (e.g., `Int64` accepting both `Value::Int64` and `Value::Timestamp`).

```moonbit
pub(open) trait FromValue {
  from_value(Value) -> Self raise PgError
}
```

### `Codec` trait (in `pgtype/`)

Each codec is a stateless struct implementing this trait. The `oid` parameter allows a single codec to handle multiple OIDs (e.g., `IntCodec` handles int2/int4/int8 with different byte widths based on OID). `prefer_format` allows codecs that only support text to declare it.

```moonbit
pub(open) trait Codec {
  fn prefer_format(self) -> Format
  fn encode(self, oid : Int, format : Format, value : Value) -> Bytes raise PgError
  fn decode(self, oid : Int, format : Format, bytes : Bytes) -> Value raise PgError
}
```

### `Type` struct (in `pgtype/`)

Extended with a `codec` field of type `&Codec` (trait object). TypeMap's OID lookup returns both the type metadata and its codec in a single access.

```moonbit
pub(all) struct Type {
  name : String
  oid : Int
  codec : &Codec
}
```

### Codec implementations (in `pgtype/`, first batch)

Each codec handles both Text and Binary format. Multiple OIDs may map to the same codec struct.

| Codec | OIDs covered | Value variant |
|-------|-------------|---------------|
| `BoolCodec` | bool (16) | `Value::Bool` |
| `Int2Codec` | int2 (21) | `Value::Int` |
| `Int4Codec` | int4 (23) | `Value::Int` |
| `Int8Codec` | int8 (20) | `Value::Int64` |
| `Float4Codec` | float4 (700) | `Value::Float` |
| `Float8Codec` | float8 (701) | `Value::Float` |
| `TextCodec` | text, varchar, bpchar, name, unknown, ... | `Value::String` |
| `ByteaCodec` | bytea (17) | `Value::Bytes` |
| `JSONCodec` | json (114) | `Value::Json` |
| `JSONBCodec` | jsonb (3802) | `Value::Json` |
| `TimestampCodec` | timestamp (1114) | `Value::Timestamp` |
| `TimestamptzCodec` | timestamptz (1184) | `Value::Timestamp` |

### Unknown OID fallback

If `TypeMap` has no entry for a given OID, return a `TextCodec` as fallback (matching pgx behavior). Types registered as `text`/`varchar`/`name`/`unknown` all use `TextCodec`.

### `Row` struct (in root package)

`values` field changes from `Array[RawValue]` to `Array[Bytes?]`. Decoding happens lazily in `Row::get::<T>(col)`:

```
match self.values[col] {
  None => T::from_value(Value::Null)
  Some(bytes) => {
    let desc = self.col_descs[col]
    let codec = pg_type_map.codec_for(desc.type_oid)
    let val = codec.decode(desc.type_oid, desc.format, bytes)
    T::from_value(val)
  }
}
```

`pg_type_map` is the global `default_map` — no need to thread it through constructors.

### Parameter encoding (in root package / wire)

Extended query flow gains a required Describe step before Bind. `StatementDescription.param_oids` provides the OID for each parameter. Each parameter is encoded via `codec.encode(param_oids[i], codec.prefer_format(), param.to_value())`. The format array in Bind is per-parameter, determined by each codec's `prefer_format()`.

### What gets removed

| Removed item | Current location | Reason |
|-------------|-----------------|--------|
| `RawValue` enum | `value.mbt` | Replaced by direct codec usage |
| `Value::to_raw()` | `value.mbt` | Encoding is now codec responsibility |
| `Value::pg_type_name()` | `value.mbt` | OID→name via TypeMap, not Value |
| `default_encode()` | `value.mbt` | Replaced by codec.encode |
| `build_params()` | `value.mbt` | Replaced by per-parameter codec encoding |
| `encode_int4/int8/float8/bool/string` | `value.mbt` | Moved to pgtype/ as internal helpers |
| `decode_int4/int8/float8/bool/string` | `value.mbt` | Moved to pgtype/ as internal helpers |
| `ToValue::pg_type()` | `value.mbt` | OID comes from Describe, not user type |
| `ToValue::to_raw_value()` | `value.mbt` | No RawValue in new design |
| `PGType` / `pg_type_*` re-exports | `value.mbt` | Moved to pgtype/ package |

## Testing Decisions

### What makes a good test

Tests should verify external behavior — round-trip encode/decode, type conversion correctness, and end-to-end query results. They should NOT test internal helper function signatures or codec struct instantiation.

### Codec tests (in `pgtype/`, no database required)

Each codec gets round-trip tests for both Text and Binary formats:
- `encode → decode` produces the same `Value` (or equivalent)
- Edge cases: min/max values, empty strings, NULL
- Follow the pattern from current `value.mbt` inline tests

### ToValue/FromValue tests (in root package, no database required)

Each built-in type's trait impl gets tested:
- `T::to_value(x)` produces expected `Value` variant
- `T::from_value(v)` round-trips
- `FromValue` raises `PgError` on mismatched variant
- Follow the pattern from current `types.mbt` inline tests

### Integration tests (in root package, requires PostgreSQL)

Existing integration tests serve as regression guards:
- Parameterized queries with all supported types
- Binary and text result formats
- Nullable columns
- Row decoding via `row.get::<T>(col)`
- Follow the pattern from current `integration_test.mbt` and `conn_test.mbt`

## Out of Scope

- Range, multirange, array, composite, domain, and enum type codecs (deferred to future work)
- `NumericCodec`, `UUIDCodec`, `DateCodec`, `TimeCodec`, `IntervalCodec`, `InetCodec`, `MacaddrCodec`, and other low-usage codecs — these remain text-only via `TextCodec` fallback or are deferred
- `RecordCodec` (composite types)
- `pg_type` re-exports at root package level (users import `pgtype/` directly)
- Changes to `wire/` protocol message handling beyond the encoding/decoding path changes needed for this refactor
- Simple query parameter encoding (simple query has no parameters)
- `COPY` protocol encoding changes (COPY uses its own text-based encoding, separate from codec)

## Further Notes

- The `ToValue`/`FromValue` impls for `Int`, `Int64`, `Double`, `Bool`, `String`, `Bytes`, `Json`, `Timestamp`, `Decimal`, `UUID`, and `Option[T]` remain in root package `types.mbt` — they are part of the public API.
- `pgtype/` uses `&Codec` trait objects stored in `Type` struct — MoonBit supports trait objects as struct fields.
- The `default_map` is a `pub let` static value in `pgtype/`, initialized at module load. Same pattern as current `wire/pgtype.mbt`.
- `Format` enum (`Text` | `Binary`) remains in `value/` since it is used by both `Codec` trait and wire messages.
- The `FieldDescription.format` field is an `Int` (0=text, 1=binary) from the wire — it must be converted to `Format` enum before passing to codec.
