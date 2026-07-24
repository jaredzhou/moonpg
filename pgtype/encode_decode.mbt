///|
/// Low-level encode/decode helpers for PostgreSQL wire-format binary values.
///
/// These are internal utilities used by codec implementations. They are
/// ported from the original `value.mbt` and moved to `pgtype/` since they
/// are codec implementation details, not part of the public `value/` API.

// ===========================================================================
// int4 (4-byte big-endian signed)
// ===========================================================================

///|
/// Encode an `Int` as a 4-byte big-endian signed integer (PG `integer` / int4).
fn encode_int4(v : Int) -> Bytes {
  let b = @buffer.Buffer(size_hint=4)
  b.write_byte(((v >> 24) & 0xff).to_byte())
  b.write_byte(((v >> 16) & 0xff).to_byte())
  b.write_byte(((v >> 8) & 0xff).to_byte())
  b.write_byte((v & 0xff).to_byte())
  b.to_bytes()
}

///|
/// Decode a 4-byte big-endian signed integer (PG `integer` / int4) from bytes.
fn decode_int4(b : Bytes) -> Int {
  (b[0].to_int() << 24) |
  (b[1].to_int() << 16) |
  (b[2].to_int() << 8) |
  b[3].to_int()
}

// ===========================================================================
// int8 (8-byte big-endian signed)
// ===========================================================================

///|
/// Encode an `Int64` as an 8-byte big-endian signed integer (PG `bigint` / int8).
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
/// Decode an 8-byte big-endian signed integer (PG `bigint` / int8) from bytes.
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

// ===========================================================================
// float8 (8-byte IEEE 754)
// ===========================================================================

///|
/// Encode a `Double` as an 8-byte big-endian IEEE 754 value (PG float8).
fn encode_float8(v : Double) -> Bytes {
  encode_int8(v.reinterpret_as_uint64().reinterpret_as_int64())
}

///|
/// Decode an 8-byte big-endian IEEE 754 value (PG float8) to `Double`.
fn decode_float8(b : Bytes) -> Double {
  decode_int8(b).reinterpret_as_double()
}

// ===========================================================================
// bool (1 byte)
// ===========================================================================

///|
/// Encode a `Bool` as a 1-byte PG boolean (0 = false, non-zero = true).
fn encode_bool(v : Bool) -> Bytes {
  let buf = @buffer.Buffer(size_hint=1)
  buf.write_byte(if v { 1 } else { 0 })
  buf.to_bytes()
}

///|
/// Decode a 1-byte PG boolean from bytes.
fn decode_bool(b : Bytes) -> Bool {
  b[0].to_int() != 0
}

// ===========================================================================
// string helpers
// ===========================================================================

///|
/// Encode a `String` as UTF-8 bytes.
fn encode_string(s : String) -> Bytes {
  @utf8.encode(s)
}

///|
/// Decode UTF-8 bytes to `String`, falling back to unchecked conversion.
fn decode_string(b : Bytes) -> String {
  @utf8.decode(b) catch {
    _ => b.to_unchecked_string()
  }
}

// ===========================================================================
// int2 (2-byte big-endian signed)
// ===========================================================================

///|
/// Encode an `Int` as a 2-byte big-endian signed integer (PG `smallint` / int2).
fn encode_int2(v : Int) -> Bytes {
  let b = @buffer.Buffer(size_hint=2)
  b.write_byte(((v >> 8) & 0xff).to_byte())
  b.write_byte((v & 0xff).to_byte())
  b.to_bytes()
}

///|
/// Decode a 2-byte big-endian signed integer (PG `smallint` / int2) from bytes.
fn decode_int2(b : Bytes) -> Int {
  let hi = b[0].to_int()
  let lo = b[1].to_int()
  if hi < 128 {
    (hi << 8) | lo
  } else {
    ((hi - 256) << 8) | lo
  }
}

// ===========================================================================
// float4 (4-byte IEEE 754)
// ===========================================================================

///|
/// Encode a `Double` as a 4-byte big-endian IEEE 754 value (PG float4).
/// Truncates from f64 to f32.
fn encode_float4(v : Double) -> Bytes {
  // Convert Double to Float (f32), then reinterpret bits as Int
  let f : Float = Float::from_double(v)
  let bits : Int = f.reinterpret_as_int()
  encode_int4(bits)
}

///|
/// Decode a 4-byte big-endian IEEE 754 value (PG float4) to `Double`.
fn decode_float4(b : Bytes) -> Double {
  let bits = decode_int4(b)
  let f : Float = Float::reinterpret_from_int(bits)
  f.to_double()
}

// ===========================================================================
// Tests
// ===========================================================================

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
test "encode_decode_int2_roundtrip" {
  let v = 32767 // max int2
  let encoded = encode_int2(v)
  let decoded = decode_int2(encoded)
  assert_eq(decoded, v, msg="int2 round-trip max")
}

///|
test "encode_decode_float8_roundtrip" {
  let v = 3.141592653589793
  let encoded = encode_float8(v)
  let decoded = decode_float8(encoded)
  assert_true((decoded - v).abs() < 1.0e-15, msg="float8 round-trip")
}

///|
test "encode_decode_float4_roundtrip" {
  let v = 3.14
  let encoded = encode_float4(v)
  let decoded = decode_float4(encoded)
  assert_true((decoded - v).abs() < 0.001, msg="float4 round-trip")
}

///|
test "encode_decode_bool_roundtrip" {
  assert_eq(decode_bool(encode_bool(true)), true, msg="bool true round-trip")
  assert_eq(decode_bool(encode_bool(false)), false, msg="bool false round-trip")
}
