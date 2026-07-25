///|
/// Built-in `ToValue` and `FromValue` implementations.
///
/// Provides round-trip encoding/decoding for all base MoonBit types
/// through PostgreSQL's `Value` type.

///|
/// Microseconds since Unix epoch (1970-01-01 00:00:00 UTC).
pub(all) struct Timestamp(Int64) derive(Eq, Debug)

// ===========================================================================
// ToValue impls
// ===========================================================================

// ---------------------------------------------------------------------------
// Int
// ---------------------------------------------------------------------------

///|
pub impl ToValue for Int with fn to_value(self) {
  @value.Value::Int(self)
}

// ---------------------------------------------------------------------------
// Int64
// ---------------------------------------------------------------------------

///|
pub impl ToValue for Int64 with fn to_value(self) {
  @value.Value::Int64(self)
}

// ---------------------------------------------------------------------------
// Double
// ---------------------------------------------------------------------------

///|
pub impl ToValue for Double with fn to_value(self) {
  @value.Value::Float(self)
}

// ---------------------------------------------------------------------------
// Bool
// ---------------------------------------------------------------------------

///|
pub impl ToValue for Bool with fn to_value(self) {
  @value.Value::Bool(self)
}

// ---------------------------------------------------------------------------
// String
// ---------------------------------------------------------------------------

///|
pub impl ToValue for String with fn to_value(self) {
  @value.Value::String(self)
}

// ---------------------------------------------------------------------------
// Bytes
// ---------------------------------------------------------------------------

///|
pub impl ToValue for Bytes with fn to_value(self) {
  @value.Value::Bytes(self)
}

// ---------------------------------------------------------------------------
// Json
// ---------------------------------------------------------------------------

///|
pub impl ToValue for Json with fn to_value(self) {
  @value.Value::Json(self)
}

// ---------------------------------------------------------------------------
// Option[T] — nullable
// ---------------------------------------------------------------------------

///|
pub impl[T : ToValue] ToValue for T? with fn to_value(self) {
  match self {
    None => @value.Value::Null
    Some(v) => v.to_value()
  }
}

// ---------------------------------------------------------------------------
// Decimal
// ---------------------------------------------------------------------------

///|
pub impl ToValue for @decimal.Decimal with fn to_value(self) {
  @value.Value::String(self.to_string())
}

// ---------------------------------------------------------------------------
// UUID
// ---------------------------------------------------------------------------

///|
pub impl ToValue for @uuid.UUID with fn to_value(self) {
  @value.Value::String(self.to_string())
}

// ---------------------------------------------------------------------------
// Timestamp
// ---------------------------------------------------------------------------

///|
pub impl ToValue for Timestamp with fn to_value(self) {
  @value.Value::Timestamp(self.0)
}

// ===========================================================================
// FromValue impls
// ===========================================================================

// ---------------------------------------------------------------------------
// Int
// ---------------------------------------------------------------------------

///|
pub impl FromValue for Int with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Int(i) => i
    _ => raise ValueError::ValueError("expected Value::Int")
  }
}

// ---------------------------------------------------------------------------
// Int64
// ---------------------------------------------------------------------------

///|
pub impl FromValue for Int64 with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Int64(i) => i
    @value.Value::Timestamp(i) => i
    _ =>
      raise ValueError::ValueError("expected Value::Int64 or Value::Timestamp")
  }
}

// ---------------------------------------------------------------------------
// Double
// ---------------------------------------------------------------------------

///|
pub impl FromValue for Double with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Float(f) => f
    _ => raise ValueError::ValueError("expected Value::Float")
  }
}

// ---------------------------------------------------------------------------
// Bool
// ---------------------------------------------------------------------------

///|
pub impl FromValue for Bool with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Bool(b) => b
    _ => raise ValueError::ValueError("expected Value::Bool")
  }
}

// ---------------------------------------------------------------------------
// String
// ---------------------------------------------------------------------------

///|
pub impl FromValue for String with fn from_value(v : @value.Value) {
  match v {
    @value.Value::String(s) => s
    _ => raise ValueError::ValueError("expected Value::String")
  }
}

// ---------------------------------------------------------------------------
// Bytes
// ---------------------------------------------------------------------------

///|
pub impl FromValue for Bytes with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Bytes(b) => b
    _ => raise ValueError::ValueError("expected Value::Bytes")
  }
}

// ---------------------------------------------------------------------------
// Json
// ---------------------------------------------------------------------------

///|
pub impl FromValue for Json with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Json(j) => j
    _ => raise ValueError::ValueError("expected Value::Json")
  }
}

// ---------------------------------------------------------------------------
// Option[T] — nullable
// ---------------------------------------------------------------------------

///|
pub impl[T : FromValue] FromValue for T? with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Null => None
    _ => Some(T::from_value(v))
  }
}

// ---------------------------------------------------------------------------
// Decimal
// ---------------------------------------------------------------------------

///|
pub impl FromValue for @decimal.Decimal with fn from_value(v : @value.Value) {
  match v {
    @value.Value::String(s) => {
      let d = @decimal.Decimal::from_string(s)
      match d {
        Some(d) => d
        None => raise ValueError::ValueError("cannot convert to Decimal")
      }
    }
    _ => raise ValueError::ValueError("expected Value::String for Decimal")
  }
}

// ---------------------------------------------------------------------------
// UUID
// ---------------------------------------------------------------------------

///|
pub impl FromValue for @uuid.UUID with fn from_value(v : @value.Value) {
  match v {
    @value.Value::String(s) =>
      @uuid.from_hex(s) catch {
        _ => raise ValueError::ValueError("cannot convert to UUID")
      }
    _ => raise ValueError::ValueError("expected Value::String for UUID")
  }
}

// ---------------------------------------------------------------------------
// Timestamp
// ---------------------------------------------------------------------------

///|
pub impl FromValue for Timestamp with fn from_value(v : @value.Value) {
  match v {
    @value.Value::Timestamp(u) => Timestamp(u)
    _ => raise ValueError::ValueError("expected Value::Timestamp")
  }
}

// ===========================================================================
// Tests
// ===========================================================================

///|
test "to_value_int" {
  let val = ToValue::to_value(42)
  assert_eq(val, @value.Value::Int(42))
}

///|
test "from_value_int_roundtrip" {
  let v : Int = FromValue::from_value(@value.Value::Int(42))
  assert_eq(v, 42)
}

///|
test "from_value_int_mismatch" {
  let mut got_error : Bool = false
  let _ = FromValue::from_value(@value.Value::String("bad")) catch {
    _ => {
      got_error = true
      0
    }
  }
  assert_true(got_error)
}

///|
test "option_to_value_some" {
  let v : Int? = Some(42)
  let val = ToValue::to_value(v)
  match val {
    @value.Value::Int(n) => assert_eq(n, 42)
    _ => fail("expected Value::Int")
  }
}

///|
test "option_to_value_none" {
  let v : Int? = None
  let val = ToValue::to_value(v)
  match val {
    @value.Value::Null => ()
    _ => fail("expected Value::Null")
  }
}

///|
test "option_from_value_null" {
  let v : Int? = FromValue::from_value(@value.Value::Null)
  match v {
    None => ()
    Some(_) => fail("expected None")
  }
}

///|
test "json_to_value" {
  let j = @json.parse("[1,2,3]")
  let val = ToValue::to_value(j)
  match val {
    @value.Value::Json(v) => assert_eq(v.stringify(), "[1,2,3]")
    _ => fail("expected Value::Json")
  }
}

///|
test "bool_from_value" {
  assert_eq(FromValue::from_value(@value.Value::Bool(true)), true)
  assert_eq(FromValue::from_value(@value.Value::Bool(false)), false)
}

// --- Timestamp ---

///|
test "timestamp_to_value" {
  let ts = Timestamp(1720528496000000L)
  let val = ToValue::to_value(ts)
  match val {
    @value.Value::Timestamp(u) => assert_eq(u, 1720528496000000L)
    _ => fail("expected Value::Timestamp")
  }
}

///|
test "timestamp_from_value" {
  let val = @value.Value::Timestamp(1720528496000000L)
  let ts : Timestamp = FromValue::from_value(val)
  assert_eq(ts.0, 1720528496000000L)
}

// --- String roundtrip ---

///|
test "string_to_value" {
  let val = ToValue::to_value("hello")
  assert_eq(val, @value.Value::String("hello"))
}

///|
test "string_from_value" {
  let v : String = FromValue::from_value(@value.Value::String("hello"))
  assert_eq(v, "hello")
}

///|
test "string_from_value_mismatch" {
  let mut ok = false
  let _ = FromValue::from_value(@value.Value::Int(42)) catch {
    _ => {
      ok = true
      ""
    }
  }
  assert_true(ok)
}

// --- Bytes roundtrip ---

///|
test "bytes_to_value" {
  let data = b"\x00\x01\xFF"
  let val = ToValue::to_value(data)
  assert_eq(val, @value.Value::Bytes(data))
}

///|
test "bytes_from_value" {
  let data = b"\x00\x01\xFF"
  let v : Bytes = FromValue::from_value(@value.Value::Bytes(data))
  assert_eq(v, data)
}

// --- Double roundtrip ---

///|
test "double_to_value" {
  let val = ToValue::to_value(3.14)
  assert_eq(val, @value.Value::Float(3.14))
}

///|
test "double_from_value" {
  let v : Double = FromValue::from_value(@value.Value::Float(3.14))
  assert_eq(v, 3.14)
}

// --- Int64 roundtrip ---

///|
test "int64_to_value" {
  let val = ToValue::to_value(42L)
  assert_eq(val, @value.Value::Int64(42L))
}

///|
test "int64_from_value" {
  let v : Int64 = FromValue::from_value(@value.Value::Int64(42L))
  assert_eq(v, 42L)
}

///|
test "int64_from_timestamp" {
  let v : Int64 = FromValue::from_value(
    @value.Value::Timestamp(1720000000000000L),
  )
  assert_eq(v, 1720000000000000L)
}

// --- NULL roundtrip via Option ---

///|
test "option_string_from_null" {
  let v : String? = FromValue::from_value(@value.Value::Null)
  match v {
    None => ()
    Some(_) => fail("expected None")
  }
}

///|
test "option_int_from_some" {
  let v : Int? = FromValue::from_value(@value.Value::Int(42))
  match v {
    Some(n) => assert_eq(n, 42)
    None => fail("expected Some(42)")
  }
}

// --- Decimal roundtrip ---

///|
test "decimal_to_value" {
  let d = @decimal.Decimal::from_string("3.14").unwrap()
  let val = ToValue::to_value(d)
  assert_eq(val, @value.Value::String("3.14"))
}

///|
test "decimal_from_value" {
  let v : @decimal.Decimal = FromValue::from_value(@value.Value::String("3.14"))
  assert_eq(v.to_string(), "3.14")
}

///|
test "decimal_from_value_invalid" {
  let mut ok = false
  let _ = FromValue::from_value(@value.Value::String("not_a_number")) catch {
    _ => {
      ok = true
      @decimal.Decimal::from_string("0").unwrap()
    }
  }
  assert_true(ok)
}

// --- UUID roundtrip ---

///|
test "uuid_from_value" {
  let v : @uuid.UUID = FromValue::from_value(
    @value.Value::String("550e8400-e29b-41d4-a716-446655440000"),
  )
  assert_eq(v.to_string(), "550e8400-e29b-41d4-a716-446655440000")
}

// --- Timestamp mismatch ---

///|
test "timestamp_from_value_mismatch" {
  let mut ok = false
  let _ = FromValue::from_value(@value.Value::String("bad")) catch {
    _ => {
      ok = true
      Timestamp(0L)
    }
  }
  assert_true(ok)
}

// --- Json roundtrip ---

///|
test "json_from_value" {
  let j = @json.parse("{\"a\":1}")
  let val = @value.Value::Json(j)
  let v : Json = FromValue::from_value(val)
  assert_eq(v.stringify(), "{\"a\":1}")
}

// --- Bool edge cases ---

///|
test "bool_from_value_all" {
  assert_eq(FromValue::from_value(@value.Value::Bool(true)), true)
  assert_eq(FromValue::from_value(@value.Value::Bool(false)), false)
}

///|
test "bool_from_value_mismatch" {
  let mut ok = false
  let _ = FromValue::from_value(@value.Value::Int(1)) catch {
    _ => {
      ok = true
      false
    }
  }
  assert_true(ok)
}
