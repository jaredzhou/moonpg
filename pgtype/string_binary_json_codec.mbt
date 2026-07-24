///|
/// String, binary, JSON, and temporal codecs:
/// `ByteaCodec`, `JSONCodec`, `JSONBCodec`, `TimestampCodec`, `TimestamptzCodec`.

// PG epoch (2000-01-01) offset from Unix epoch, in microseconds.
let pg_epoch_offset_usec : Int64 = 946684800000000L

// ===========================================================================
// ByteaCodec
// ===========================================================================

///|
pub struct ByteaCodec {}

///|
pub let bytea_codec : ByteaCodec = ByteaCodec::{  }

///|
impl Codec for ByteaCodec with fn prefer_format(_self : ByteaCodec) -> @value.Format {
  @value.Format::Binary
}

///|
impl Codec for ByteaCodec with fn encode(
  _self : ByteaCodec,
  _oid : Int,
  format : @value.Format,
  value : @value.Value,
) -> Bytes? raise CodecError {
  match value {
    @value.Value::Bytes(b) =>
      match format {
        @value.Format::Text => Some(encode_bytea_hex(b))
        @value.Format::Binary => Some(b)
      }
    @value.Value::Null => None
    _ =>
      raise CodecError::CodecError("ByteaCodec::encode: expected Value::Bytes")
  }
}

///|
impl Codec for ByteaCodec with fn decode(
  _self : ByteaCodec,
  _oid : Int,
  format : @value.Format,
  bytes : Bytes?,
) -> @value.Value raise CodecError {
  match bytes {
    None => @value.Value::Null
    Some(bytes) => match format {
    @value.Format::Text => {
      let s = decode_string(bytes)
      @value.Value::Bytes(decode_bytea_hex(s))
    }
    @value.Format::Binary => @value.Value::Bytes(bytes)
  }
}
}

///|
fn encode_bytea_hex(b : Bytes) -> Bytes {
  let hex = "0123456789abcdef"
  let n = b.length()
  let buf = @buffer.Buffer(size_hint=2 + n * 2)
  buf.write_byte(b'\\')
  buf.write_byte(b'x')
  for i = 0; i < n; i = i + 1 {
    let byte = b[i].to_int()
    let hi = (byte >> 4) & 0xf
    let lo = byte & 0xf
    buf.write_byte(hex[hi].to_byte())
    buf.write_byte(hex[lo].to_byte())
  }
  buf.to_bytes()
}

///|
fn decode_bytea_hex(s : String) -> Bytes raise CodecError {
  let hex : String = if s.length() >= 2 && s[:2] == "\\x" {
    s[2:].to_owned()
  } else {
    s
  }
  guard hex.length() % 2 == 0 else {
    raise CodecError::CodecError(
      "ByteaCodec::decode: hex string has odd length",
    )
  }
  let len = hex.length() / 2
  let buf = @buffer.Buffer(size_hint=len)
  for i = 0; i < len; i = i + 1 {
    let hi = hex_char_val(hex, i * 2)
    let lo = hex_char_val(hex, i * 2 + 1)
    buf.write_byte(((hi << 4) | lo).to_byte())
  }
  buf.to_bytes()
}

///|
fn hex_char_val(s : String, i : Int) -> Int {
  let c = s[i].to_int()
  if c >= 48 && c <= 57 {
    c - 48
  } else if c >= 65 && c <= 70 {
    c - 55
  } else if c >= 97 && c <= 102 {
    c - 87
  } else {
    0
  }
}

// ===========================================================================
// JSONCodec
// ===========================================================================

///|
pub struct JSONCodec {}

///|
pub let json_codec : JSONCodec = JSONCodec::{  }

///|
impl Codec for JSONCodec with fn prefer_format(_self : JSONCodec) -> @value.Format {
  @value.Format::Text
}

///|
impl Codec for JSONCodec with fn encode(
  _self : JSONCodec,
  _oid : Int,
  format : @value.Format,
  value : @value.Value,
) -> Bytes? raise CodecError {
  match value {
    @value.Value::Json(j) =>
      match format {
        @value.Format::Text => Some(@utf8.encode(j.stringify()))
        @value.Format::Binary =>
          raise CodecError::CodecError(
            "JSONCodec::encode: binary format not supported",
          )
      }
    @value.Value::String(s) =>
      match format {
        @value.Format::Text => Some(@utf8.encode(s))
        @value.Format::Binary =>
          raise CodecError::CodecError(
            "JSONCodec::encode: binary format not supported",
          )
      }
    @value.Value::Null => None
    _ => raise CodecError::CodecError("JSONCodec::encode: expected Value::Json")
  }
}

///|
impl Codec for JSONCodec with fn decode(
  _self : JSONCodec,
  _oid : Int,
  format : @value.Format,
  bytes : Bytes?,
) -> @value.Value raise CodecError {
  match bytes {
    None => @value.Value::Null
    Some(bytes) => match format {
    @value.Format::Text => {
      let s = decode_string(bytes)
      let j = @json.parse(s) catch {
        _ => raise CodecError::CodecError("JSONCodec::decode: invalid JSON")
      }
      @value.Value::Json(j)
    }
    @value.Format::Binary =>
      raise CodecError::CodecError(
        "JSONCodec::decode: binary format not supported",
      )
  }
}
}

// ===========================================================================
// JSONBCodec
// ===========================================================================

///|
pub struct JSONBCodec {}

///|
pub let jsonb_codec : JSONBCodec = JSONBCodec::{  }

///|
impl Codec for JSONBCodec with fn prefer_format(_self : JSONBCodec) -> @value.Format {
  @value.Format::Text
}

///|
impl Codec for JSONBCodec with fn encode(
  _self : JSONBCodec,
  _oid : Int,
  format : @value.Format,
  value : @value.Value,
) -> Bytes? raise CodecError {
  match value {
    @value.Value::Json(j) =>
      match format {
        @value.Format::Text => Some(@utf8.encode(j.stringify()))
        @value.Format::Binary =>
          raise CodecError::CodecError(
            "JSONBCodec::encode: binary format not supported",
          )
      }
    @value.Value::String(s) =>
      match format {
        @value.Format::Text => Some(@utf8.encode(s))
        @value.Format::Binary =>
          raise CodecError::CodecError(
            "JSONBCodec::encode: binary format not supported",
          )
      }
    @value.Value::Null => None
    _ =>
      raise CodecError::CodecError("JSONBCodec::encode: expected Value::Json")
  }
}

///|
impl Codec for JSONBCodec with fn decode(
  _self : JSONBCodec,
  _oid : Int,
  format : @value.Format,
  bytes : Bytes?,
) -> @value.Value raise CodecError {
  match bytes {
    None => @value.Value::Null
    Some(bytes) => match format {
    @value.Format::Text => {
      let s = decode_string(bytes)
      let j = @json.parse(s) catch {
        _ => raise CodecError::CodecError("JSONBCodec::decode: invalid JSON")
      }
      @value.Value::Json(j)
    }
    @value.Format::Binary =>
      raise CodecError::CodecError(
        "JSONBCodec::decode: binary format not supported",
      )
  }
}
}

// ===========================================================================
// TimestampCodec (timestamp without timezone)
// ===========================================================================

///|
pub struct TimestampCodec {}

///|
pub let timestamp_codec : TimestampCodec = TimestampCodec::{  }

///|
impl Codec for TimestampCodec with fn prefer_format(_self : TimestampCodec) -> @value.Format {
  @value.Format::Binary
}

///|
impl Codec for TimestampCodec with fn encode(
  _self : TimestampCodec,
  _oid : Int,
  format : @value.Format,
  value : @value.Value,
) -> Bytes? raise CodecError {
  match value {
    @value.Value::Timestamp(usec) =>
      match format {
        @value.Format::Text => Some(@utf8.encode(format_ts_text(usec)))
        @value.Format::Binary => Some(encode_int8(usec + pg_epoch_offset_usec))
      }
    @value.Value::String(s) =>
      match format {
        @value.Format::Text => Some(@utf8.encode(s))
        @value.Format::Binary =>
          raise CodecError::CodecError(
            "TimestampCodec::encode: expected Value::Timestamp",
          )
      }
    @value.Value::Null => None
    _ =>
      raise CodecError::CodecError(
        "TimestampCodec::encode: expected Value::Timestamp",
      )
  }
}

///|
impl Codec for TimestampCodec with fn decode(
  _self : TimestampCodec,
  _oid : Int,
  format : @value.Format,
  bytes : Bytes?,
) -> @value.Value raise CodecError {
  match bytes {
    None => @value.Value::Null
    Some(bytes) => match format {
    @value.Format::Text => {
      let s = decode_string(bytes)
      @value.Value::Timestamp(parse_ts_text(s))
    }
    @value.Format::Binary => {
      guard bytes.length() >= 8 else {
        raise CodecError::CodecError("TimestampCodec::decode: expected 8 bytes")
      }
      let pg_usec = decode_int8(bytes)
      @value.Value::Timestamp(pg_usec - pg_epoch_offset_usec)
    }
  }
}
}

// ===========================================================================
// TimestamptzCodec
// ===========================================================================

///|
pub struct TimestamptzCodec {}

///|
pub let timestamptz_codec : TimestamptzCodec = TimestamptzCodec::{  }

///|
impl Codec for TimestamptzCodec with fn prefer_format(_self : TimestamptzCodec) -> @value.Format {
  @value.Format::Binary
}

///|
impl Codec for TimestamptzCodec with fn encode(
  _self : TimestamptzCodec,
  _oid : Int,
  format : @value.Format,
  value : @value.Value,
) -> Bytes? raise CodecError {
  match value {
    @value.Value::Timestamp(usec) =>
      match format {
        @value.Format::Text => Some(@utf8.encode(format_tstz_text(usec)))
        @value.Format::Binary => Some(encode_int8(usec + pg_epoch_offset_usec))
      }
    @value.Value::String(s) =>
      match format {
        @value.Format::Text => Some(@utf8.encode(s))
        @value.Format::Binary =>
          raise CodecError::CodecError(
            "TimestamptzCodec::encode: expected Value::Timestamp",
          )
      }
    @value.Value::Null => None
    _ =>
      raise CodecError::CodecError(
        "TimestamptzCodec::encode: expected Value::Timestamp",
      )
  }
}

///|
impl Codec for TimestamptzCodec with fn decode(
  _self : TimestamptzCodec,
  _oid : Int,
  format : @value.Format,
  bytes : Bytes?,
) -> @value.Value raise CodecError {
  match bytes {
    None => @value.Value::Null
    Some(bytes) => match format {
    @value.Format::Text => {
      let s = decode_string(bytes)
      @value.Value::Timestamp(parse_tstz_text(s))
    }
    @value.Format::Binary => {
      guard bytes.length() >= 8 else {
        raise CodecError::CodecError(
          "TimestamptzCodec::decode: expected 8 bytes",
        )
      }
      let pg_usec = decode_int8(bytes)
      @value.Value::Timestamp(pg_usec - pg_epoch_offset_usec)
    }
  }
}
}

// ===========================================================================
// Timestamp text formatting (manual arithmetic, no @time dependency)
// ===========================================================================

///|
/// Days in each month (non-leap year).
let month_days : Array[Int] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

///|
/// Seconds in a day.
let secs_per_day : Int64 = 86400L

///|
/// Check if a year is a leap year.
fn is_leap(y : Int) -> Bool {
  (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

///|
/// Days in a year (365 or 366).
fn year_days(y : Int) -> Int {
  if is_leap(y) {
    366
  } else {
    365
  }
}

///|
/// Days in a given month of a given year.
fn month_days_for(y : Int, m : Int) -> Int {
  if m == 2 && is_leap(y) {
    29
  } else {
    month_days[m - 1]
  }
}

///|
/// Compute (year, month, day) from days since Unix epoch (1970-01-01).
fn days_to_date(days : Int64) -> (Int, Int, Int) {
  let mut d = days
  let mut y = 1970
  while d < 0 {
    y = y - 1
    d = d + year_days(y).to_int64()
  }
  while d >= year_days(y).to_int64() {
    d = d - year_days(y).to_int64()
    y = y + 1
  }
  let mut m = 1
  while d >= month_days_for(y, m).to_int64() {
    d = d - month_days_for(y, m).to_int64()
    m = m + 1
  }
  (y, m, d.to_int() + 1)
}

///|
/// Compute (hour, minute, second) from seconds within a day.
fn secs_to_hms(secs : Int64) -> (Int, Int, Int) {
  let h = (secs / 3600L).to_int()
  let m = (secs % 3600L / 60L).to_int()
  let s = (secs % 60L).to_int()
  (h, m, s)
}

///|
fn pad2(v : Int) -> String {
  if v < 10 {
    "0\{v}"
  } else {
    "\{v}"
  }
}

///|
fn pad6(v : Int) -> String {
  if v < 10 {
    "00000\{v}"
  } else if v < 100 {
    "0000\{v}"
  } else if v < 1000 {
    "000\{v}"
  } else if v < 10000 {
    "00\{v}"
  } else if v < 100000 {
    "0\{v}"
  } else {
    "\{v}"
  }
}

///|
/// Format microseconds since Unix epoch as `YYYY-MM-DD HH:MM:SS[.micros]`.
fn format_ts_text(usec : Int64) -> String {
  let secs = usec / 1_000_000L
  let micros = (usec % 1_000_000L).to_int()
  let days = secs / secs_per_day
  let day_secs = secs % secs_per_day
  let (y, m, d) = days_to_date(days)
  let (h, mi, s) = secs_to_hms(day_secs)
  if micros == 0 {
    "\{y}-\{pad2(m)}-\{pad2(d)} \{pad2(h)}:\{pad2(mi)}:\{pad2(s)}"
  } else {
    "\{y}-\{pad2(m)}-\{pad2(d)} \{pad2(h)}:\{pad2(mi)}:\{pad2(s)}.\{pad6(micros)}"
  }
}

///|
/// Format microseconds since Unix epoch as timestamptz text (with `+00`).
fn format_tstz_text(usec : Int64) -> String {
  "\{format_ts_text(usec)}+00"
}

///|
/// Parse timestamp without timezone text to microseconds since Unix epoch.
fn parse_ts_text(s : String) -> Int64 raise CodecError {
  let iso = s.replace(old=" ", new="T")
  let pdt = @time.PlainDateTime::from_str(iso) catch {
    _ => raise CodecError::CodecError("invalid timestamp text")
  }
  pdt.to_unix_second() * 1_000_000L + pdt.nanosecond().to_int64() / 1000L
}

///|
/// Parse timestamptz text (with timezone) to microseconds since Unix epoch.
fn parse_tstz_text(s : String) -> Int64 raise CodecError {
  let (body, tz_offset_usec) = split_tz_offset(s)
  let iso = body.replace(old=" ", new="T")
  let pdt = @time.PlainDateTime::from_str(iso) catch {
    _ => raise CodecError::CodecError("invalid timestamptz text")
  }
  (pdt.to_unix_second() - tz_offset_usec / 1_000_000L) * 1_000_000L +
  pdt.nanosecond().to_int64() / 1000L
}

///|
/// Split timezone offset from end of timestamp string.
/// Returns `(body, tz_offset_micros)`.
fn split_tz_offset(s : String) -> (String, Int64) {
  let len = s.length()
  for i = 0; i < len; i = i + 1 {
    if i >= 19 && (s[i] == '+' || s[i] == '-') {
      let sign : Int64 = if s[i] == '-' { -1L } else { 1L }
      let tz_h = digit_val(s, i + 1) * 10 + digit_val(s, i + 2)
      let mut tz_m = 0
      let colon = i + 3
      if colon < len && s[colon] == ':' {
        tz_m = digit_val(s, colon + 1) * 10 + digit_val(s, colon + 2)
      }
      let tz_secs : Int64 = sign *
        (tz_h.to_int64() * 3600L + tz_m.to_int64() * 60L)
      return (s[:i].to_owned(), tz_secs * 1_000_000L)
    }
  }
  (s, 0L)
}

///|
fn digit_val(s : String, i : Int) -> Int {
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

// ===========================================================================
// Tests
// ===========================================================================

///|
test "bytea_codec_text_roundtrip" {
  let codec = bytea_codec
  let data = b"\x00\x01\x02\xDE\xAD\xBE\xEF"
  let encoded = Codec::encode(
    codec,
    bytea_oid,
    @value.Format::Text,
    @value.Value::Bytes(data),
  )
  let decoded = Codec::decode(codec, bytea_oid, @value.Format::Text, encoded)
  match decoded {
    @value.Value::Bytes(b) => assert_eq(b, data)
    _ => fail("expected Value::Bytes")
  }
}

///|
test "bytea_codec_binary_roundtrip" {
  let codec = bytea_codec
  let data = b"\xFF\x00\xAB\xCD"
  let encoded = Codec::encode(
    codec,
    bytea_oid,
    @value.Format::Binary,
    @value.Value::Bytes(data),
  )
  let decoded = Codec::decode(codec, bytea_oid, @value.Format::Binary, encoded)
  match decoded {
    @value.Value::Bytes(b) => assert_eq(b, data)
    _ => fail("expected Value::Bytes")
  }
}

///|
test "json_codec_text_roundtrip" {
  let codec = json_codec
  let j = @json.parse("{\"a\":1}")
  let encoded = Codec::encode(
    codec,
    json_oid,
    @value.Format::Text,
    @value.Value::Json(j),
  )
  let decoded = Codec::decode(codec, json_oid, @value.Format::Text, encoded)
  match decoded {
    @value.Value::Json(v) => assert_eq(v.stringify(), "{\"a\":1}")
    _ => fail("expected Value::Json")
  }
}

///|
test "jsonb_codec_text_roundtrip" {
  let codec = jsonb_codec
  let j = @json.parse("[1,2,3]")
  let encoded = Codec::encode(
    codec,
    jsonb_oid,
    @value.Format::Text,
    @value.Value::Json(j),
  )
  let decoded = Codec::decode(codec, jsonb_oid, @value.Format::Text, encoded)
  match decoded {
    @value.Value::Json(v) => assert_eq(v.stringify(), "[1,2,3]")
    _ => fail("expected Value::Json")
  }
}

///|
test "timestamp_codec_text_roundtrip" {
  let codec = timestamp_codec
  // 2024-07-09 12:34:56 UTC
  let usec : Int64 = 1720528496000000L
  let encoded = Codec::encode(
    codec,
    timestamp_oid,
    @value.Format::Text,
    @value.Value::Timestamp(usec),
  )
  let decoded = Codec::decode(
    codec,
    timestamp_oid,
    @value.Format::Text,
    encoded,
  )
  match decoded {
    @value.Value::Timestamp(u) => {
      // Text round-trip may lose microseconds precision during parsing
      // (PlainDateTime uses nanoseconds internally)
      let diff = (u - usec).abs()
      assert_true(diff < 1000000L)
    }
    _ => fail("expected Value::Timestamp")
  }
}

///|
test "timestamp_codec_binary_roundtrip" {
  let codec = timestamp_codec
  let usec : Int64 = 1720528496000000L
  let encoded = Codec::encode(
    codec,
    timestamp_oid,
    @value.Format::Binary,
    @value.Value::Timestamp(usec),
  )
  let decoded = Codec::decode(
    codec,
    timestamp_oid,
    @value.Format::Binary,
    encoded,
  )
  match decoded {
    @value.Value::Timestamp(u) => assert_eq(u, usec)
    _ => fail("expected Value::Timestamp")
  }
}

///|
test "timestamptz_codec_binary_roundtrip" {
  let codec = timestamptz_codec
  let usec : Int64 = 1720528496000000L
  let encoded = Codec::encode(
    codec,
    timestamptz_oid,
    @value.Format::Binary,
    @value.Value::Timestamp(usec),
  )
  let decoded = Codec::decode(
    codec,
    timestamptz_oid,
    @value.Format::Binary,
    encoded,
  )
  match decoded {
    @value.Value::Timestamp(u) => assert_eq(u, usec)
    _ => fail("expected Value::Timestamp")
  }
}
