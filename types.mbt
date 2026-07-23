///|
/// `ToValue` and `FromRaw` implementations for built-in types.
/// Core traits and types live in `value.mbt`.
///
/// Each type's `ToValue` and `FromRaw` impls are grouped together.

// ---------------------------------------------------------------------------
// Int
// ---------------------------------------------------------------------------

///|
pub impl ToValue for Int with fn to_value(self) {
  Value::Int(self)
}

///|
pub impl FromRaw for Int with fn from_raw(v : RawValue) raise PgError {
  match v {
    Null => raise_null("Int")
    Bytes(Text, b) => {
      let s = decode_string(b)
      @string.parse_int(s) catch {
        _ => raise PgError::QueryError("cannot convert '\{s}' to Int")
      }
    }
    Bytes(Binary, b) => decode_int4(b)
  }
}

// ---------------------------------------------------------------------------
// Int64
// ---------------------------------------------------------------------------

///|
pub impl ToValue for Int64 with fn to_value(self) {
  Value::Int64(self)
}

///|
pub impl FromRaw for Int64 with fn from_raw(v : RawValue) raise PgError {
  match v {
    Null => raise_null("Int64")
    Bytes(Text, b) => {
      let s = decode_string(b)
      @string.parse_int64(s) catch {
        _ => raise PgError::QueryError("cannot convert '\{s}' to Int64")
      }
    }
    Bytes(Binary, b) => decode_int8(b)
  }
}

// ---------------------------------------------------------------------------
// Double
// ---------------------------------------------------------------------------

///|
pub impl ToValue for Double with fn to_value(self) {
  Value::Float(self)
}

///|
pub impl FromRaw for Double with fn from_raw(v : RawValue) raise PgError {
  match v {
    Null => raise_null("Double")
    Bytes(Text, b) => {
      let s = decode_string(b)
      @string.parse_double(s) catch {
        _ => raise PgError::QueryError("cannot convert '\{s}' to Double")
      }
    }
    Bytes(Binary, b) => decode_float8(b)
  }
}

// ---------------------------------------------------------------------------
// Bool
// ---------------------------------------------------------------------------

///|
pub impl ToValue for Bool with fn to_value(self) {
  Value::Bool(self)
}

///|
pub impl FromRaw for Bool with fn from_raw(v : RawValue) raise PgError {
  match v {
    Null => raise_null("Bool")
    Bytes(Text, b) => {
      let s = decode_string(b)
      @string.parse_bool(s) catch {
        _ => raise PgError::QueryError("cannot convert '\{s}' to Bool")
      }
    }
    Bytes(Binary, b) => decode_bool(b)
  }
}

// ---------------------------------------------------------------------------
// String
// ---------------------------------------------------------------------------

///|
pub impl ToValue for String with fn to_value(self) {
  Value::String(self)
}

///|
pub impl FromRaw for String with fn from_raw(v : RawValue) raise PgError {
  match v {
    Null => raise_null("String")
    Bytes(Text, b) => decode_string(b)
    Bytes(Binary, b) => decode_string(b)
  }
}

// ---------------------------------------------------------------------------
// Bytes
// ---------------------------------------------------------------------------

///|
pub impl ToValue for Bytes with fn to_value(self) {
  Value::Bytes(self)
}

///|
pub impl FromRaw for Bytes with fn from_raw(v : RawValue) raise PgError {
  match v {
    Null => raise_null("Bytes")
    Bytes(_, b) => b
  }
}

// ---------------------------------------------------------------------------
// Option[T] — nullable
// ---------------------------------------------------------------------------

///|
pub impl[T : ToValue] ToValue for T? with fn to_value(self) {
  match self {
    None => Value::Null
    Some(v) => v.to_value()
  }
}

///|
pub impl[T : ToValue] ToValue for T? with fn pg_type(self) -> @wire.Type {
  match self {
    None => @wire.Type::{ name: "unknown", oid: 0 }
    Some(v) => v.pg_type()
  }
}

///|
pub impl[T : FromRaw] FromRaw for T? with fn from_raw(v : RawValue) raise PgError {
  match v {
    Null => None
    Bytes(_, _) => Some(T::from_raw(v))
  }
}

// ---------------------------------------------------------------------------
// Json
// ---------------------------------------------------------------------------

///|
pub impl ToValue for Json with fn to_value(self) {
  Value::String(self.stringify())
}

///|
pub impl ToValue for Json with fn pg_type(_self) -> @wire.Type {
  @wire.default_map.type_for_name("jsonb").unwrap()
}

///|
pub impl FromRaw for Json with fn from_raw(v : RawValue) raise PgError {
  match v {
    Null => raise_null("Json")
    Bytes(Text, b) =>
      @json.parse(decode_string(b)) catch {
        _ => raise PgError::QueryError("cannot parse cell as JSON")
      }
    Bytes(Binary, _) => raise_binary()
  }
}

// ---------------------------------------------------------------------------
// Timestamp
// ---------------------------------------------------------------------------

///|
pub(all) struct Timestamp(Int64)

///|
let pg_epoch_offset : Int64 = 946684800000000L

///|
fn parse_ts(s : String) -> Timestamp raise PgError {
  let (body, tz_offset_secs) = split_tz(s)
  let iso = body.replace(old=" ", new="T")
  let pdt = @time.PlainDateTime::from_str(iso) catch {
    _ => raise PgError::QueryError("cannot parse timestamp: '\{s}'")
  }
  let usec = (pdt.to_unix_second() - tz_offset_secs.to_int64()) * 1_000_000L +
    pdt.nanosecond().to_int64() / 1000L
  Timestamp(usec)
}

///|
fn split_tz(s : String) -> (String, Int) {
  let len = s.length()
  for i = 19; i < len; i = i + 1 {
    if s[i] == '+' || s[i] == '-' {
      let sign = if s[i] == '-' { -1 } else { 1 }
      let tz_h = digit(s, i + 1) * 10 + digit(s, i + 2)
      let mut tz_m = 0
      let colon = i + 3
      if colon < len && s[colon] == ':' {
        tz_m = digit(s, colon + 1) * 10 + digit(s, colon + 2)
      }
      return (s[:i].to_owned(), sign * (tz_h * 3600 + tz_m * 60))
    }
  }
  (s, 0)
}

///|
fn digit(s : String, i : Int) -> Int {
  if i >= s.length() {
    return 0
  }
  let c = s[i].to_int() - 48
  if c >= 0 && c <= 9 {
    c
  } else {
    0
  }
}

///|
pub impl ToValue for Timestamp with fn to_value(self) {
  Value::Int64(self.0 - pg_epoch_offset)
}

///|
pub impl ToValue for Timestamp with fn pg_type(_self) -> @wire.Type {
  @wire.default_map.type_for_name("timestamptz").unwrap()
}

///|
pub impl FromRaw for Timestamp with fn from_raw(v : RawValue) raise PgError {
  match v {
    Null => raise_null("Timestamp")
    Bytes(Text, b) => parse_ts(decode_string(b))
    Bytes(Binary, b) => Timestamp(decode_int8(b) + pg_epoch_offset)
  }
}

// ---------------------------------------------------------------------------
// Decimal
// ---------------------------------------------------------------------------

///|
pub impl ToValue for @decimal.Decimal with fn to_value(self) {
  Value::String(self.to_string())
}

///|
pub impl ToValue for @decimal.Decimal with fn pg_type(_self) -> @wire.Type {
  @wire.default_map.type_for_name("numeric").unwrap()
}

///|
pub impl FromRaw for @decimal.Decimal with fn from_raw(v : RawValue) raise PgError {
  match v {
    Null => raise_null("Decimal")
    Bytes(Text, b) => {
      let d = @decimal.Decimal::from_string(decode_string(b))
      match d {
        Some(d) => d
        None => raise PgError::QueryError("cannot convert cell to Decimal")
      }
    }
    Bytes(Binary, _) => raise_binary()
  }
}

// ---------------------------------------------------------------------------
// UUID
// ---------------------------------------------------------------------------

///|
pub impl ToValue for @uuid.UUID with fn to_value(self) {
  Value::String(self.to_string())
}

///|
pub impl ToValue for @uuid.UUID with fn pg_type(_self) -> @wire.Type {
  @wire.default_map.type_for_name("uuid").unwrap()
}

///|
pub impl FromRaw for @uuid.UUID with fn from_raw(v : RawValue) raise PgError {
  match v {
    Null => raise_null("UUID")
    Bytes(Text, b) =>
      @uuid.from_hex(decode_string(b)) catch {
        _ => raise PgError::QueryError("cannot convert cell to UUID")
      }
    Bytes(Binary, _) => raise_binary()
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

///|
test "parse_ts_basic" {
  let ts = parse_ts("2024-07-09 12:34:56")
  assert_eq(ts.0, 1720528496000000L, msg="parse_ts basic")
}

///|
test "parse_ts_with_millis" {
  let ts = parse_ts("2024-07-09 12:34:56.789")
  assert_eq(ts.0, 1720528496789000L, msg="parse_ts millis")
}

///|
test "parse_ts_with_micros" {
  let ts = parse_ts("2024-07-09 12:34:56.789123")
  assert_eq(ts.0, 1720528496789123L, msg="parse_ts micros")
}

///|
test "parse_ts_with_tz" {
  let ts = parse_ts("2024-07-09 12:34:56+08")
  assert_eq(ts.0, 1720499696000000L, msg="parse_ts +08")
}

///|
test "timestamp_epoch" {
  let ts = parse_ts("1970-01-01 00:00:00")
  assert_eq(ts.0, 0L, msg="unix epoch")
}

///|
test "timestamp_before_epoch" {
  let ts = parse_ts("1969-12-31 23:59:59")
  assert_eq(ts.0, -1000000L, msg="before epoch")
}
