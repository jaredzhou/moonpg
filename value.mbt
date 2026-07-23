///|
/// PostgreSQL parameter value. Used for both encoding (client → server via
/// `ToValue`) and decoding (server → client via `FromRaw`).
pub enum Value {
  Null
  Bool(Bool)
  Int(Int)
  Int64(Int64)
  Float(Double)
  String(String)
  Bytes(Bytes)
}

///|
/// Data format for a PostgreSQL cell or parameter.
pub enum Format {
  Text
  Binary
} derive(Eq)

///|
fn Format::to_int(self : Format) -> Int {
  match self {
    Text => 0
    Binary => 1
  }
}

///|
/// Raw value read from a result cell. Carries the format (text or binary)
/// and the raw bytes from libpq. Convert to `Value` via `to_value()`.
pub(all) enum RawValue {
  Null
  Bytes(Format, Bytes)
}

///|
/// Convert a `RawValue` (format + bytes from libpq) to a `Value`.
/// Prefer `FromRaw` for typed decoding; this is a best-effort convenience.
///
/// * `Null` → `Value::Null`
/// * `Bytes(Text, b)` → `Value::String` (UTF-8 decoded)
/// * `Bytes(Binary, b)` → `Value::Bytes` (raw bytes)
pub fn RawValue::to_value(self : RawValue) -> Value {
  match self {
    Null => Value::Null
    Bytes(f, b) =>
      match f {
        Format::Text => {
          let s = @utf8.decode(b) catch { _ => b.to_unchecked_string() }
          Value::String(s)
        }
        Format::Binary => Value::Bytes(b)
      }
  }
}

///|
/// Build `(param_values, param_formats)` arrays for the wire protocol's
/// `execute_params` from an array of `Value`s.
pub fn build_params(params : Array[RawValue]) -> (Array[Bytes?], Array[Int]) {
  let n = params.length()
  let values : Array[Bytes?] = Array::makei(n, fn(_) { None })
  let formats : Array[Int] = Array::makei(n, fn(_) { 0 })
  for i, v in params {
    let (val, fmt) = match v {
      RawValue::Null => (None, 0)
      RawValue::Bytes(f, b) => (Some(b), f.to_int())
    }
    ignore(values.set(i, val))
    ignore(formats.set(i, fmt))
  }
  (values, formats)
}

///|
/// PG `integer` (int4) — 4-byte big-endian signed.
fn encode_int4(v : Int) -> Bytes {
  let b = @buffer.Buffer(size_hint=4)

  b.write_byte(((v >> 24) & 0xff).to_byte())
  b.write_byte(((v >> 16) & 0xff).to_byte())
  b.write_byte(((v >> 8) & 0xff).to_byte())
  b.write_byte((v & 0xff).to_byte())

  b.to_bytes()
}

///|
fn decode_int4(b : Bytes) -> Int {
  (b[0].to_int() << 24) |
  (b[1].to_int() << 16) |
  (b[2].to_int() << 8) |
  b[3].to_int()
}

///|
/// PG `bigint` (int8) — 8-byte big-endian signed.
fn encode_int8(v : Int64) -> Bytes {
  let b = @buffer.Buffer(size_hint=8)

  b.write_byte(((v >> 56) & 0xff).to_byte())
  b.write_byte(((v >> 48) & 0xff).to_byte())
  b.write_byte(((v >> 40) & 0xff).to_byte())
  b.write_byte(((v >> 32) & 0xff).to_byte())
  b.write_byte(((v >> 24) & 0xff).to_byte())
  b.write_byte(((v >> 16) & 0xff).to_byte())
  b.write_byte(((v >> 8) & 0xff).to_byte())
  b.write_byte((v & 0xff).to_byte())

  b.to_bytes()
}

///|
fn decode_int8(b : Bytes) -> Int64 {
  (b[0].to_int64() << 56) |
  (b[1].to_int64() << 48) |
  (b[2].to_int64() << 40) |
  (b[3].to_int64() << 32) |
  (b[4].to_int64() << 24) |
  (b[5].to_int64() << 16) |
  (b[6].to_int64() << 8) |
  b[7].to_int64()
}

///|
/// PG `double precision` (float8) — 8-byte big-endian IEEE 754.
fn encode_float8(v : Double) -> Bytes {
  encode_int8(v.reinterpret_as_uint64().reinterpret_as_int64())
}

///|
fn decode_float8(b : Bytes) -> Double {
  decode_int8(b).reinterpret_as_double()
}

///|
/// PG `boolean` — 1 byte (0 = false, non-zero = true).
fn encode_bool(v : Bool) -> Bytes {
  let buf = @buffer.Buffer(size_hint=1)
  buf.write_byte(if v { 1 } else { 0 })
  buf.to_bytes()
}

///|
fn decode_bool(b : Bytes) -> Bool {
  b[0].to_int() != 0
}

///|
/// Encode a `Value` into a `RawValue` in the given format.
///
/// * `Text` — PostgreSQL text representation (e.g. `"42"`, `"t"`, `"f"`).
/// * `Binary` — PostgreSQL binary representation (network byte order).
///
/// Returns `RawValue::Null` for `Value::Null` (caller should emit SQL NULL
/// instead).
pub fn Value::to_raw(self : Value, format : Format) -> RawValue {
  match self {
    Null => RawValue::Null
    Bool(v) =>
      match format {
        Text => RawValue::Bytes(Text, encode_string(if v { "t" } else { "f" }))
        Binary => RawValue::Bytes(Binary, encode_bool(v))
      }
    Int(v) =>
      match format {
        Text => RawValue::Bytes(Text, encode_string(v.to_string()))
        Binary => RawValue::Bytes(Binary, encode_int4(v))
      }
    Int64(v) =>
      match format {
        Text => RawValue::Bytes(Text, encode_string(v.to_string()))
        Binary => RawValue::Bytes(Binary, encode_int8(v))
      }
    Float(v) =>
      match format {
        Text => RawValue::Bytes(Text, encode_string(v.to_string()))
        Binary => RawValue::Bytes(Binary, encode_float8(v))
      }
    String(v) => RawValue::Bytes(format, encode_string(v))
    Bytes(v) => RawValue::Bytes(format, v)
  }
}

///|
fn encode_string(s : String) -> Bytes {
  @utf8.encode(s)
}

///|
fn decode_string(b : Bytes) -> String {
  @utf8.decode(b) catch {
    _ => b.to_unchecked_string()
  }
}

///|
/// Default encode: `Value` → `RawValue` for parameter transmission.
/// `Null` → `Null`. `Bytes` → binary format; everything else → text format.
pub fn default_encode(v : Value) -> RawValue {
  match v {
    Null => RawValue::Null
    Bytes(_) => v.to_raw(Binary)
    _ => v.to_raw(Text)
  }
}

///|

///|
/// Return the PostgreSQL type name for this value (e.g. `"int4"`, `"text"`).
pub fn Value::pg_type_name(self : Value) -> String {
  match self {
    Null => "unknown"
    Bool(_) => "bool"
    Int(_) => "int4"
    Int64(_) => "int8"
    Float(_) => "float8"
    String(_) => "text"
    Bytes(_) => "bytea"
  }
}

///|
/// Types that can be used as SQL parameters.
pub(open) trait ToValue {
  fn to_value(Self) -> Value
  fn to_raw_value(Self) -> RawValue = _
  fn pg_type(Self) -> @wire.Type = _
}

///|
impl ToValue with fn to_raw_value(self) {
  default_encode(self.to_value())
}

///|
impl ToValue with fn pg_type(self) -> @wire.Type {
  let name = self.to_value().pg_type_name()
  match @wire.default_map.type_for_name(name) {
    Some(t) => t
    None => @wire.Type::{ name: "unknown", oid: 0 }
  }
}

///|
/// Types that can be decoded from a PostgreSQL cell value.
///
/// `from_raw` receives a `RawValue` directly from the libpq result (format +
/// raw bytes). Implementations should handle:
///
/// * `RawValue::Null` — SQL NULL; raise or return a default
/// * `RawValue::Bytes(Text, b)` — text-format value (UTF-8 decode then parse)
/// * `RawValue::Bytes(Binary, b)` — binary wire-protocol value
///
/// The basic implementations raise `PgError::QueryError` on `Null`; use
/// `Option[T]` for nullable columns.

///|
pub(open) trait FromRaw {
  fn from_raw(RawValue) -> Self raise PgError
}

///|
pub fn[T] raise_null(label : String) -> T raise PgError {
  raise PgError::QueryError(
    "cannot decode NULL as \{label}; use Option[\{label}] for nullable columns",
  )
}

///|
pub fn[T] raise_binary() -> T raise PgError {
  raise PgError::QueryError("binary-format cell values are not supported yet")
}

///|
test "decode_int4_positive" {
  // 42 = 0x0000002A in big-endian
  let b = b"\x00\x00\x00\x2A"
  assert_eq(decode_int4(b), 42, msg="int4 positive")
}

///|
test "decode_int4_negative" {
  // -1 = 0xFFFFFFFF in big-endian
  let b = b"\xFF\xFF\xFF\xFF"
  assert_eq(decode_int4(b), -1, msg="int4 negative")
}

///|
test "decode_int4_zero" {
  let b = b"\x00\x00\x00\x00"
  assert_eq(decode_int4(b), 0, msg="int4 zero")
}

///|
test "decode_int8_positive" {
  // 1234567890123 = 0x0000011F71FB04CB
  let b = b"\x00\x00\x01\x1F\x71\xFB\x04\xCB"
  assert_eq(decode_int8(b), 1234567890123L, msg="int8 positive")
}

///|
test "decode_int8_negative" {
  // -9223372036854775808 = 0x8000000000000000
  let b = b"\x80\x00\x00\x00\x00\x00\x00\x00"
  assert_eq(decode_int8(b), -9223372036854775808L, msg="int8 minimum")
}

///|
test "decode_bool_true" {
  let b = b"\x01"
  assert_eq(decode_bool(b), true, msg="bool true")
}

///|
test "decode_bool_false" {
  let b = b"\x00"
  assert_eq(decode_bool(b), false, msg="bool false")
}

///|
test "encode_decode_float8_roundtrip" {
  let v = 3.141592653589793
  let encoded = encode_float8(v)
  let decoded = decode_float8(encoded)
  assert_true((decoded - v).abs() < 1.0e-15, msg="float8 round-trip")
}

///|
test "encode_decode_int4_roundtrip" {
  let v = -42
  let encoded = encode_int4(v)
  let decoded = decode_int4(encoded)
  assert_eq(decoded, v, msg="int4 round-trip")
}

///|
test "encode_decode_int8_roundtrip" {
  let v = -9_223_372_036_854_775_807L
  let encoded = encode_int8(v)
  let decoded = decode_int8(encoded)
  assert_eq(decoded, v, msg="int8 round-trip")
}

///|
/// End-to-end: binary-format FromRaw for basic types.
test "from_raw_binary_int" {
  let b = b"\x00\x00\x00\x2A" // 42
  let v : Int = FromRaw::from_raw(RawValue::Bytes(Binary, b))
  assert_eq(v, 42, msg="from_raw binary Int")
}

///|
test "from_raw_binary_bool" {
  let v : Bool = FromRaw::from_raw(RawValue::Bytes(Binary, b"\x01"))
  assert_eq(v, true, msg="from_raw binary Bool true")

  let v2 : Bool = FromRaw::from_raw(RawValue::Bytes(Binary, b"\x00"))
  assert_eq(v2, false, msg="from_raw binary Bool false")
}

///|
test "from_raw_binary_string" {
  let s = "hello"
  let b = @utf8.encode(s)
  let v : String = FromRaw::from_raw(RawValue::Bytes(Binary, b))
  assert_eq(v, "hello", msg="from_raw binary String")
}

///|
test "from_raw_binary_nullable" {
  // Non-null binary value
  let b = b"\x00\x00\x00\x07" // 7
  let v : Int? = FromRaw::from_raw(RawValue::Bytes(Binary, b))
  match v {
    Some(x) => assert_eq(x, 7, msg="nullable binary non-null")
    None => fail("expected Some(7)")
  }

  // Null
  let v2 : Int? = FromRaw::from_raw(RawValue::Null)
  match v2 {
    Some(_) => fail("expected None")
    None => ()
  }
}
