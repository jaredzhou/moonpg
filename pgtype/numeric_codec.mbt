///|
/// Numeric and boolean codecs: `BoolCodec`, `Int2Codec`, `Int4Codec`,
/// `Int8Codec`, `Float4Codec`, `Float8Codec`.
///
/// Each codec handles both Text and Binary format.

// ===========================================================================
// BoolCodec
// ===========================================================================

pub struct BoolCodec {}

///|
pub let bool_codec : BoolCodec = BoolCodec::{  }

///|
impl Codec for BoolCodec with fn prefer_format(_self : BoolCodec) -> @value.Format {
  @value.Format::Binary
}

///|
impl Codec for BoolCodec with fn encode(
  _self : BoolCodec,
  _oid : Int,
  format : @value.Format,
  value : @value.Value,
) -> Bytes? raise CodecError {
  match value {
    @value.Value::Bool(v) =>
      match format {
        @value.Format::Text => Some(@utf8.encode(if v { "t" } else { "f" }))
        @value.Format::Binary => Some(encode_bool(v))
      }
    @value.Value::String(s) =>
      match format {
        @value.Format::Text => Some(@utf8.encode(s))
        @value.Format::Binary => {
          let b = if s == "t" {
            true
          } else if s == "f" {
            false
          } else {
            raise CodecError::CodecError(
              "BoolCodec::encode: expected \"t\" or \"f\", got \"\{s}\"",
            )
          }
          Some(encode_bool(b))
        }
      }
    @value.Value::Null => None
    _ => raise CodecError::CodecError("BoolCodec::encode: expected Value::Bool")
  }
}

///|
impl Codec for BoolCodec with fn decode(
  _self : BoolCodec,
  _oid : Int,
  format : @value.Format,
  bytes : Bytes?,
) -> @value.Value raise CodecError {
  match bytes {
    None => @value.Value::Null
    Some(bytes) =>
      match format {
        @value.Format::Text => {
          let s = decode_string(bytes)
          match s {
            "t" => @value.Value::Bool(true)
            "f" => @value.Value::Bool(false)
            _ =>
              raise CodecError::CodecError(
                "BoolCodec::decode: invalid text bool: \{s}",
              )
          }
        }
        @value.Format::Binary => {
          guard bytes.length() >= 1 else {
            raise CodecError::CodecError(
              "BoolCodec::decode: expected 1 byte, got \{bytes.length()}",
            )
          }
          @value.Value::Bool(decode_bool(bytes))
        }
      }
  }
}

// ===========================================================================
// Int2Codec
// ===========================================================================

///|
pub struct Int2Codec {}

///|
pub let int2_codec : Int2Codec = Int2Codec::{  }

///|
impl Codec for Int2Codec with fn prefer_format(_self : Int2Codec) -> @value.Format {
  @value.Format::Binary
}

///|
impl Codec for Int2Codec with fn encode(
  _self : Int2Codec,
  _oid : Int,
  format : @value.Format,
  value : @value.Value,
) -> Bytes? raise CodecError {
  match value {
    @value.Value::Int(v) =>
      match format {
        @value.Format::Text => Some(@utf8.encode(v.to_string()))
        @value.Format::Binary => Some(encode_int2(v))
      }
    @value.Value::Null => None
    _ => raise CodecError::CodecError("Int2Codec::encode: expected Value::Int")
  }
}

///|
impl Codec for Int2Codec with fn decode(
  _self : Int2Codec,
  _oid : Int,
  format : @value.Format,
  bytes : Bytes?,
) -> @value.Value raise CodecError {
  match bytes {
    None => @value.Value::Null
    Some(bytes) =>
      match format {
        @value.Format::Text => {
          let s = decode_string(bytes)
          let v = @string.parse_int(s) catch {
            _ =>
              raise CodecError::CodecError(
                "Int2Codec::decode: invalid text: \{s}",
              )
          }
          @value.Value::Int(v)
        }
        @value.Format::Binary => {
          guard bytes.length() >= 2 else {
            raise CodecError::CodecError(
              "Int2Codec::decode: expected 2 bytes, got \{bytes.length()}",
            )
          }
          @value.Value::Int(decode_int2(bytes))
        }
      }
  }
}

// ===========================================================================
// Int4Codec
// ===========================================================================

///|
pub struct Int4Codec {}

///|
pub let int4_codec : Int4Codec = Int4Codec::{  }

///|
impl Codec for Int4Codec with fn prefer_format(_self : Int4Codec) -> @value.Format {
  @value.Format::Binary
}

///|
impl Codec for Int4Codec with fn encode(
  _self : Int4Codec,
  _oid : Int,
  format : @value.Format,
  value : @value.Value,
) -> Bytes? raise CodecError {
  match value {
    @value.Value::Int(v) =>
      match format {
        @value.Format::Text => Some(@utf8.encode(v.to_string()))
        @value.Format::Binary => Some(encode_int4(v))
      }
    @value.Value::Null => None
    _ => raise CodecError::CodecError("Int4Codec::encode: expected Value::Int")
  }
}

///|
impl Codec for Int4Codec with fn decode(
  _self : Int4Codec,
  _oid : Int,
  format : @value.Format,
  bytes : Bytes?,
) -> @value.Value raise CodecError {
  match bytes {
    None => @value.Value::Null
    Some(bytes) =>
      match format {
        @value.Format::Text => {
          let s = decode_string(bytes)
          let v = @string.parse_int(s) catch {
            _ =>
              raise CodecError::CodecError(
                "Int4Codec::decode: invalid text: \{s}",
              )
          }
          @value.Value::Int(v)
        }
        @value.Format::Binary => {
          guard bytes.length() >= 4 else {
            raise CodecError::CodecError(
              "Int4Codec::decode: expected 4 bytes, got \{bytes.length()}",
            )
          }
          @value.Value::Int(decode_int4(bytes))
        }
      }
  }
}

// ===========================================================================
// Int8Codec
// ===========================================================================

///|
pub struct Int8Codec {}

///|
pub let int8_codec : Int8Codec = Int8Codec::{  }

///|
impl Codec for Int8Codec with fn prefer_format(_self : Int8Codec) -> @value.Format {
  @value.Format::Binary
}

///|
impl Codec for Int8Codec with fn encode(
  _self : Int8Codec,
  _oid : Int,
  format : @value.Format,
  value : @value.Value,
) -> Bytes? raise CodecError {
  match value {
    @value.Value::Int64(v) =>
      match format {
        @value.Format::Text => Some(@utf8.encode(v.to_string()))
        @value.Format::Binary => Some(encode_int8(v))
      }
    @value.Value::Int(v) =>
      match format {
        @value.Format::Text => Some(@utf8.encode(v.to_string()))
        @value.Format::Binary => Some(encode_int8(v.to_int64()))
      }
    @value.Value::Null => None
    _ =>
      raise CodecError::CodecError("Int8Codec::encode: expected Value::Int64")
  }
}

///|
impl Codec for Int8Codec with fn decode(
  _self : Int8Codec,
  _oid : Int,
  format : @value.Format,
  bytes : Bytes?,
) -> @value.Value raise CodecError {
  match bytes {
    None => @value.Value::Null
    Some(bytes) =>
      match format {
        @value.Format::Text => {
          let s = decode_string(bytes)
          let v = @string.parse_int64(s) catch {
            _ =>
              raise CodecError::CodecError(
                "Int8Codec::decode: invalid text: \{s}",
              )
          }
          @value.Value::Int64(v)
        }
        @value.Format::Binary => {
          guard bytes.length() >= 8 else {
            raise CodecError::CodecError(
              "Int8Codec::decode: expected 8 bytes, got \{bytes.length()}",
            )
          }
          @value.Value::Int64(decode_int8(bytes))
        }
      }
  }
}

// ===========================================================================
// Float4Codec
// ===========================================================================

///|
pub struct Float4Codec {}

///|
pub let float4_codec : Float4Codec = Float4Codec::{  }

///|
impl Codec for Float4Codec with fn prefer_format(_self : Float4Codec) -> @value.Format {
  @value.Format::Binary
}

///|
impl Codec for Float4Codec with fn encode(
  _self : Float4Codec,
  _oid : Int,
  format : @value.Format,
  value : @value.Value,
) -> Bytes? raise CodecError {
  match value {
    @value.Value::Float(v) =>
      match format {
        @value.Format::Text => Some(@utf8.encode(v.to_string()))
        @value.Format::Binary => Some(encode_float4(v))
      }
    @value.Value::Int(v) =>
      match format {
        @value.Format::Text => Some(@utf8.encode(v.to_string()))
        @value.Format::Binary => Some(encode_float4(v.to_double()))
      }
    @value.Value::Int64(v) =>
      match format {
        @value.Format::Text => Some(@utf8.encode(v.to_string()))
        @value.Format::Binary => Some(encode_float4(v.to_double()))
      }
    @value.Value::Null => None
    _ =>
      raise CodecError::CodecError("Float4Codec::encode: expected Value::Float")
  }
}

///|
impl Codec for Float4Codec with fn decode(
  _self : Float4Codec,
  _oid : Int,
  format : @value.Format,
  bytes : Bytes?,
) -> @value.Value raise CodecError {
  match bytes {
    None => @value.Value::Null
    Some(bytes) =>
      match format {
        @value.Format::Text => {
          let s = decode_string(bytes)
          let v = @string.parse_double(s) catch {
            _ =>
              raise CodecError::CodecError(
                "Float4Codec::decode: invalid text: \{s}",
              )
          }
          @value.Value::Float(v)
        }
        @value.Format::Binary => {
          guard bytes.length() >= 4 else {
            raise CodecError::CodecError(
              "Float4Codec::decode: expected 4 bytes, got \{bytes.length()}",
            )
          }
          @value.Value::Float(decode_float4(bytes))
        }
      }
  }
}

// ===========================================================================
// Float8Codec
// ===========================================================================

///|
pub struct Float8Codec {}

///|
pub let float8_codec : Float8Codec = Float8Codec::{  }

///|
impl Codec for Float8Codec with fn prefer_format(_self : Float8Codec) -> @value.Format {
  @value.Format::Binary
}

///|
impl Codec for Float8Codec with fn encode(
  _self : Float8Codec,
  _oid : Int,
  format : @value.Format,
  value : @value.Value,
) -> Bytes? raise CodecError {
  match value {
    @value.Value::Float(v) =>
      match format {
        @value.Format::Text => Some(@utf8.encode(v.to_string()))
        @value.Format::Binary => Some(encode_float8(v))
      }
    @value.Value::Int(v) =>
      match format {
        @value.Format::Text => Some(@utf8.encode(v.to_string()))
        @value.Format::Binary => Some(encode_float8(v.to_double()))
      }
    @value.Value::Int64(v) =>
      match format {
        @value.Format::Text => Some(@utf8.encode(v.to_string()))
        @value.Format::Binary => Some(encode_float8(v.to_double()))
      }
    @value.Value::Null => None
    _ =>
      raise CodecError::CodecError("Float8Codec::encode: expected Value::Float")
  }
}

///|
impl Codec for Float8Codec with fn decode(
  _self : Float8Codec,
  _oid : Int,
  format : @value.Format,
  bytes : Bytes?,
) -> @value.Value raise CodecError {
  match bytes {
    None => @value.Value::Null
    Some(bytes) =>
      match format {
        @value.Format::Text => {
          let s = decode_string(bytes)
          let v = @string.parse_double(s) catch {
            _ =>
              raise CodecError::CodecError(
                "Float8Codec::decode: invalid text: \{s}",
              )
          }
          @value.Value::Float(v)
        }
        @value.Format::Binary => {
          guard bytes.length() >= 8 else {
            raise CodecError::CodecError(
              "Float8Codec::decode: expected 8 bytes, got \{bytes.length()}",
            )
          }
          @value.Value::Float(decode_float8(bytes))
        }
      }
  }
}

// ===========================================================================
// Tests
// ===========================================================================

///|
test "bool_codec_text_roundtrip" {
  let codec = bool_codec
  for v in [true, false] {
    let encoded = Codec::encode(
      codec,
      bool_oid,
      @value.Format::Text,
      @value.Value::Bool(v),
    )
    let decoded = Codec::decode(codec, bool_oid, @value.Format::Text, encoded)
    match decoded {
      @value.Value::Bool(b) => assert_eq(b, v)
      _ => fail("expected Value::Bool")
    }
  }
}

///|
test "bool_codec_binary_roundtrip" {
  let codec = bool_codec
  for v in [true, false] {
    let encoded = Codec::encode(
      codec,
      bool_oid,
      @value.Format::Binary,
      @value.Value::Bool(v),
    )
    let decoded = Codec::decode(codec, bool_oid, @value.Format::Binary, encoded)
    match decoded {
      @value.Value::Bool(b) => assert_eq(b, v)
      _ => fail("expected Value::Bool")
    }
  }
}

///|
test "int4_codec_text_roundtrip" {
  let codec = int4_codec
  for v in [0, 42, -1, 2147483647, -2147483648] {
    let encoded = Codec::encode(
      codec,
      int4_oid,
      @value.Format::Text,
      @value.Value::Int(v),
    )
    let decoded = Codec::decode(codec, int4_oid, @value.Format::Text, encoded)
    match decoded {
      @value.Value::Int(n) => assert_eq(n, v)
      _ => fail("expected Value::Int")
    }
  }
}

///|
test "int4_codec_binary_roundtrip" {
  let codec = int4_codec
  for v in [0, 42, -1, 2147483647, -2147483648] {
    let encoded = Codec::encode(
      codec,
      int4_oid,
      @value.Format::Binary,
      @value.Value::Int(v),
    )
    let decoded = Codec::decode(codec, int4_oid, @value.Format::Binary, encoded)
    match decoded {
      @value.Value::Int(n) => assert_eq(n, v)
      _ => fail("expected Value::Int")
    }
  }
}

///|
test "int8_codec_text_roundtrip" {
  let codec = int8_codec
  for v in [0L, 42L, -1L] {
    let encoded = Codec::encode(
      codec,
      int8_oid,
      @value.Format::Text,
      @value.Value::Int64(v),
    )
    let decoded = Codec::decode(codec, int8_oid, @value.Format::Text, encoded)
    match decoded {
      @value.Value::Int64(n) => assert_eq(n, v)
      _ => fail("expected Value::Int64")
    }
  }
}

///|
test "int8_codec_binary_roundtrip" {
  let codec = int8_codec
  for v in [0L, 42L, -1L, 9223372036854775807L, -9223372036854775808L] {
    let encoded = Codec::encode(
      codec,
      int8_oid,
      @value.Format::Binary,
      @value.Value::Int64(v),
    )
    let decoded = Codec::decode(codec, int8_oid, @value.Format::Binary, encoded)
    match decoded {
      @value.Value::Int64(n) => assert_eq(n, v)
      _ => fail("expected Value::Int64")
    }
  }
}

///|
test "float8_codec_text_roundtrip" {
  let codec = float8_codec
  let v = 3.141592653589793
  let encoded = Codec::encode(
    codec,
    float8_oid,
    @value.Format::Text,
    @value.Value::Float(v),
  )
  let decoded = Codec::decode(codec, float8_oid, @value.Format::Text, encoded)
  match decoded {
    @value.Value::Float(f) => assert_true((f - v).abs() < 0.0001)
    _ => fail("expected Value::Float")
  }
}

///|
test "float8_codec_binary_roundtrip" {
  let codec = float8_codec
  let v = 3.141592653589793
  let encoded = Codec::encode(
    codec,
    float8_oid,
    @value.Format::Binary,
    @value.Value::Float(v),
  )
  let decoded = Codec::decode(codec, float8_oid, @value.Format::Binary, encoded)
  match decoded {
    @value.Value::Float(f) => assert_true((f - v).abs() < 1.0e-15)
    _ => fail("expected Value::Float")
  }
}

///|
test "numeric_codec_type_mismatch" {
  let codec = int4_codec
  let mut got_error : Bool = false
  let _ = Codec::encode(
    codec,
    int4_oid,
    @value.Format::Binary,
    @value.Value::String("bad"),
  ) catch {
    _ => {
      got_error = true
      None
    }
  }
  assert_true(got_error, msg="expected CodecError for type mismatch")
}

// ===========================================================================
// Edge case tests
// ===========================================================================

// --- BoolCodec ---
test "bool_codec_string_compat_t" {
  let codec = bool_codec
  let encoded = Codec::encode(codec, bool_oid, @value.Format::Binary, @value.Value::String("t"))
  let decoded = Codec::decode(codec, bool_oid, @value.Format::Binary, encoded)
  assert_eq(decoded, @value.Value::Bool(true))
}

test "bool_codec_string_compat_f" {
  let codec = bool_codec
  let encoded = Codec::encode(codec, bool_oid, @value.Format::Binary, @value.Value::String("f"))
  let decoded = Codec::decode(codec, bool_oid, @value.Format::Binary, encoded)
  assert_eq(decoded, @value.Value::Bool(false))
}

test "bool_codec_string_compat_bad" {
  let codec = bool_codec
  let mut ok = false
  let _ = Codec::encode(codec, bool_oid, @value.Format::Binary, @value.Value::String("bad")) catch {
    _ => { ok = true; None }
  }
  assert_true(ok, msg="expected error for invalid bool string")
}

test "bool_codec_null" {
  let codec = bool_codec
  let encoded = Codec::encode(codec, bool_oid, @value.Format::Binary, @value.Value::Null)
  assert_eq(encoded, None)
  let decoded = Codec::decode(codec, bool_oid, @value.Format::Binary, None)
  assert_eq(decoded, @value.Value::Null)
}

// --- Int2Codec ---
test "int2_codec_text_roundtrip" {
  let codec = int2_codec
  for v in [0, 32767, -32768, 1, -1] {
    let encoded = Codec::encode(codec, int2_oid, @value.Format::Text, @value.Value::Int(v))
    let decoded = Codec::decode(codec, int2_oid, @value.Format::Text, encoded)
    match decoded {
      @value.Value::Int(n) => assert_eq(n, v)
      _ => fail("expected Value::Int")
    }
  }
}

test "int2_codec_binary_roundtrip" {
  let codec = int2_codec
  for v in [0, 32767, -32768] {
    let encoded = Codec::encode(codec, int2_oid, @value.Format::Binary, @value.Value::Int(v))
    let decoded = Codec::decode(codec, int2_oid, @value.Format::Binary, encoded)
    match decoded {
      @value.Value::Int(n) => assert_eq(n, v)
      _ => fail("expected Value::Int")
    }
  }
}

test "int2_codec_null" {
  let codec = int2_codec
  let encoded = Codec::encode(codec, int2_oid, @value.Format::Binary, @value.Value::Null)
  assert_eq(encoded, None)
}

// --- Float4Codec ---
test "float4_codec_text_roundtrip" {
  let codec = float4_codec
  let v = 3.14
  let encoded = Codec::encode(codec, float4_oid, @value.Format::Text, @value.Value::Float(v))
  let decoded = Codec::decode(codec, float4_oid, @value.Format::Text, encoded)
  match decoded {
    @value.Value::Float(f) => assert_true((f - v).abs() < 0.01)
    _ => fail("expected Value::Float")
  }
}

test "float4_codec_binary_roundtrip" {
  let codec = float4_codec
  let v = -2.5
  let encoded = Codec::encode(codec, float4_oid, @value.Format::Binary, @value.Value::Float(v))
  let decoded = Codec::decode(codec, float4_oid, @value.Format::Binary, encoded)
  match decoded {
    @value.Value::Float(f) => assert_true((f - v).abs() < 0.001)
    _ => fail("expected Value::Float")
  }
}

test "float4_codec_null" {
  let codec = float4_codec
  let encoded = Codec::encode(codec, float4_oid, @value.Format::Binary, @value.Value::Null)
  assert_eq(encoded, None)
}

// --- Int8Codec: Int → Int64 compatibility ---
test "int8_codec_int_compat" {
  let codec = int8_codec
  // Value::Int should widen to Int64
  let encoded = Codec::encode(codec, int8_oid, @value.Format::Binary, @value.Value::Int(42))
  let decoded = Codec::decode(codec, int8_oid, @value.Format::Binary, encoded)
  assert_eq(decoded, @value.Value::Int64(42L))
}

test "int8_codec_null" {
  let codec = int8_codec
  let encoded = Codec::encode(codec, int8_oid, @value.Format::Binary, @value.Value::Null)
  assert_eq(encoded, None)
}

// --- Float8Codec: Int/Int64 → Double compatibility ---
test "float8_codec_int_compat" {
  let codec = float8_codec
  let encoded = Codec::encode(codec, float8_oid, @value.Format::Binary, @value.Value::Int(3))
  let decoded = Codec::decode(codec, float8_oid, @value.Format::Binary, encoded)
  assert_eq(decoded, @value.Value::Float(3.0))
}

test "float8_codec_int64_compat" {
  let codec = float8_codec
  let encoded = Codec::encode(codec, float8_oid, @value.Format::Binary, @value.Value::Int64(99L))
  let decoded = Codec::decode(codec, float8_oid, @value.Format::Binary, encoded)
  assert_eq(decoded, @value.Value::Float(99.0))
}

test "float8_codec_null" {
  let codec = float8_codec
  let encoded = Codec::encode(codec, float8_oid, @value.Format::Binary, @value.Value::Null)
  assert_eq(encoded, None)
}

// --- Int4Codec edge values ---
test "int4_codec_edge_values" {
  let codec = int4_codec
  for v in [0, 2147483647, -2147483648] {
    let encoded = Codec::encode(codec, int4_oid, @value.Format::Binary, @value.Value::Int(v))
    let decoded = Codec::decode(codec, int4_oid, @value.Format::Binary, encoded)
    match decoded {
      @value.Value::Int(n) => assert_eq(n, v)
      _ => fail("expected Value::Int")
    }
  }
}

test "int4_codec_null" {
  let codec = int4_codec
  let encoded = Codec::encode(codec, int4_oid, @value.Format::Binary, @value.Value::Null)
  assert_eq(encoded, None)
}
