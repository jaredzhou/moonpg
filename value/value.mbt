///|
/// Value conversion error.
pub(all) suberror ValueError {
  ValueError(String)
} derive(Debug)

// ===========================================================================
// Value
// ===========================================================================

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

// ===========================================================================
// ToValue trait
// ===========================================================================

///|
/// Types that can be converted to a `Value` for use as SQL parameters.
///
/// ```moonbit nocheck
/// impl ToValue for MyType with fn to_value(self) -> Value {
///   ...
/// }
///
/// let val = my_val.to_value()
/// ```
pub(open) trait ToValue {
  fn to_value(Self) -> Value
}

// ===========================================================================
// FromValue trait
// ===========================================================================

///|
/// Types that can be decoded from a `Value`.
///
/// Implementations should be strict: raise `ValueError` when the `Value`
/// variant doesn't match the expected type.
///
/// ```moonbit nocheck
/// impl FromValue for MyType with fn from_value(v : Value) -> MyType raise ValueError {
///   match v {
///     Value::String(s) => parse_my_type(s)
///     _ => raise ValueError::ValueError("expected Value::String, got ...")
///   }
/// }
/// ```
pub(open) trait FromValue {
  fn from_value(Value) -> Self raise ValueError
}

// ===========================================================================
// Built-in type implementations
// ===========================================================================

// ---------------------------------------------------------------------------
// Int
// ---------------------------------------------------------------------------

///|
pub impl ToValue for Int with fn to_value(self) {
  Value::Int(self)
}

///|
pub impl FromValue for Int with fn from_value(v : Value) {
  match v {
    Value::Int(i) => i
    _ => raise ValueError::ValueError("expected Value::Int")
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
pub impl FromValue for Int64 with fn from_value(v : Value) {
  match v {
    Value::Int64(i) => i
    Value::Timestamp(i) => i
    _ =>
      raise ValueError::ValueError("expected Value::Int64 or Value::Timestamp")
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
pub impl FromValue for Double with fn from_value(v : Value) {
  match v {
    Value::Float(f) => f
    _ => raise ValueError::ValueError("expected Value::Float")
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
pub impl FromValue for Bool with fn from_value(v : Value) {
  match v {
    Value::Bool(b) => b
    _ => raise ValueError::ValueError("expected Value::Bool")
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
pub impl FromValue for String with fn from_value(v : Value) {
  match v {
    Value::String(s) => s
    _ => raise ValueError::ValueError("expected Value::String")
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
pub impl FromValue for Bytes with fn from_value(v : Value) {
  match v {
    Value::Bytes(b) => b
    _ => raise ValueError::ValueError("expected Value::Bytes")
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
pub impl[T : FromValue] FromValue for T? with fn from_value(v : Value) {
  match v {
    Value::Null => None
    _ => Some(T::from_value(v))
  }
}

// ---------------------------------------------------------------------------
// Json
// ---------------------------------------------------------------------------

///|
pub impl ToValue for Json with fn to_value(self) {
  Value::Json(self)
}

///|
pub impl FromValue for Json with fn from_value(v : Value) {
  match v {
    Value::Json(j) => j
    _ => raise ValueError::ValueError("expected Value::Json")
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
pub impl FromValue for @decimal.Decimal with fn from_value(v : Value) {
  match v {
    Value::String(s) => {
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
pub impl ToValue for @uuid.UUID with fn to_value(self) {
  Value::String(self.to_string())
}

///|
pub impl FromValue for @uuid.UUID with fn from_value(v : Value) {
  match v {
    Value::String(s) =>
      @uuid.from_hex(s) catch {
        _ => raise ValueError::ValueError("cannot convert to UUID")
      }
    _ => raise ValueError::ValueError("expected Value::String for UUID")
  }
}

// ===========================================================================
// Tests
// ===========================================================================

///|
test "to_value_int" {
  let val = ToValue::to_value(42)
  assert_eq(val, Value::Int(42))
}

///|
test "from_value_int_roundtrip" {
  let v : Int = FromValue::from_value(Value::Int(42))
  assert_eq(v, 42)
}

///|
test "from_value_int_mismatch" {
  let mut got_error : Bool = false
  let _ = FromValue::from_value(Value::String("bad")) catch {
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
    Value::Int(n) => assert_eq(n, 42)
    _ => fail("expected Value::Int")
  }
}

///|
test "option_to_value_none" {
  let v : Int? = None
  let val = ToValue::to_value(v)
  match val {
    Value::Null => ()
    _ => fail("expected Value::Null")
  }
}

///|
test "option_from_value_null" {
  let v : Int? = FromValue::from_value(Value::Null)
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
    Value::Json(v) => assert_eq(v.stringify(), "[1,2,3]")
    _ => fail("expected Value::Json")
  }
}

///|
test "bool_from_value" {
  assert_eq(FromValue::from_value(Value::Bool(true)), true)
  assert_eq(FromValue::from_value(Value::Bool(false)), false)
}

// ===========================================================================
// Timestamp
// ===========================================================================

///|
/// Microseconds since Unix epoch (1970-01-01 00:00:00 UTC).
pub(all) struct Timestamp(Int64)

///|
pub impl ToValue for Timestamp with fn to_value(self) {
  Value::Timestamp(self.0)
}

///|
pub impl FromValue for Timestamp with fn from_value(v : Value) {
  match v {
    Value::Timestamp(u) => Timestamp(u)
    _ => raise ValueError::ValueError("expected Value::Timestamp")
  }
}

test "timestamp_to_value" {
  let ts = Timestamp::Timestamp(1720528496000000L)
  let val = ToValue::to_value(ts)
  match val {
    Value::Timestamp(u) => assert_eq(u, 1720528496000000L)
    _ => fail("expected Value::Timestamp")
  }
}

test "timestamp_from_value" {
  let val = Value::Timestamp(1720528496000000L)
  let ts : Timestamp = FromValue::from_value(val)
  assert_eq(ts.0, 1720528496000000L)
}
