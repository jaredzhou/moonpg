///|
/// `ToValue` and `FromValue` implementations for `Timestamp`.
/// Built-in type impls (Int, String, Json, …) live in `value/`.

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

// ---------------------------------------------------------------------------
// New @value.ToValue / @value.FromValue impls (only for types defined here)
// ---------------------------------------------------------------------------

///|
pub impl @value.ToValue for Timestamp with fn to_value(self) {
  @value.Value::Timestamp(self.0)
}

///|
pub impl @value.FromValue for Timestamp with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Timestamp(u) => Timestamp(u)
    _ =>
      raise @value.ValueError::ValueError(
        "expected Value::Timestamp, got other variant",
      )
  }
}
