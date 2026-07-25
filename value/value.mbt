///|
/// PostgreSQL value type used for encoding (client → server via `ToValue`)
/// and decoding (server → client via `FromValue`).
///
/// Variants map to PostgreSQL types as follows:
///
/// | Variant           | PG types                                  |
/// |-------------------|-------------------------------------------|
/// | `Null`            | SQL NULL                                  |
/// | `Bool`            | bool (16)                                 |
/// | `Int`             | int2 (21), int4 (23)                      |
/// | `Int64`           | int8 (20)                                 |
/// | `Float`           | float4 (700), float8 (701)                |
/// | `String`          | text, varchar, bpchar, name, uuid, …      |
/// | `Bytes`           | bytea (17)                                |
/// | `Timestamp(Int64)` | timestamp (1114), timestamptz (1184)      |
/// | `Json(Json)`      | json (114), jsonb (3802)                  |
pub(all) enum Value {
  Null
  Bool(Bool)
  Int(Int)
  Int64(Int64)
  Float(Double)
  String(String)
  Bytes(Bytes)
  Timestamp(Int64)
  Json(Json)
} derive(Eq, Debug)

// ===========================================================================
// Format
// ===========================================================================

///|
/// Data format for a PostgreSQL cell or parameter.
///
/// `Text` (format code 0) — human-readable representation.
/// `Binary` (format code 1) — compact wire-protocol representation.
pub(all) enum Format {
  Text
  Binary
} derive(Eq, Debug)
