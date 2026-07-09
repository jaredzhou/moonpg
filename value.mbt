///|
/// PostgreSQL parameter value. Used for both encoding (client → server via
/// `ToValue`) and decoding (server → client via `FromValue`).
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
}

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
///
/// * `Null` → `Value::Null`
/// * `Bytes(Text, b)` → `Value::String` (UTF-8 decoded)
/// * `Bytes(Binary, b)` → `Value::Bytes` (raw bytes, no decoding)
pub fn RawValue::to_value(self : RawValue) -> Value {
  match self {
    Null => Value::Null
    Bytes(f, b) => match f {
      Format::Text => {
        let s = try @utf8.decode(b) catch { _ => b.to_unchecked_string() }
        Value::String(s)
      }
      Format::Binary => Value::Bytes(b)
    }
  }
}

///|
/// Internal struct for passing encoded parameters to the FFI layer.
pub(all) struct EncodedParams {
  values : FixedArray[Bytes]
  lengths : FixedArray[Int]
  formats : FixedArray[Int]
  nulls : FixedArray[Bool]
}

///|
fn encode_i32(v : Int) -> Bytes {
  let b = @buffer.Buffer(size_hint=4)

  b.write_byte(((v >> 24) & 0xff).to_byte())
  b.write_byte(((v >> 16) & 0xff).to_byte())
  b.write_byte(((v >> 8) & 0xff).to_byte())
  b.write_byte((v & 0xff).to_byte())

  b.to_bytes()
}

///|
fn encode_i64(v : Int64) -> Bytes {
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
/// Encode a `Value` into raw bytes in the given format.
///
/// * `Text` — PostgreSQL text representation (e.g. `"42"`, `"t"`, `"f"`).
/// * `Binary` — PostgreSQL binary representation (network byte order).
///
/// Returns `None` for `Value::Null` (caller should emit SQL NULL instead)
/// and for `Value::Float` in binary format (not yet supported).
pub fn Value::to_raw(self : Value, format : Format) -> Bytes? {
  match self {
    Null => None
    Bool(v) => match format {
      Text => Some(encode_string(if v { "t" } else { "f" }))
      Binary => {
        let buf : @buffer.Buffer = Buffer()
        buf.write_byte(if v { 1 } else { 0 })
        Some(buf.to_bytes())
      }
    }
    Int(v) => match format {
      Text => Some(encode_string(v.to_string()))
      Binary => Some(encode_i32(v))
    }
    Int64(v) => match format {
      Text => Some(encode_string(v.to_string()))
      Binary => Some(encode_i64(v))
    }
    Float(v) => match format {
      Text => Some(encode_string(v.to_string()))
      Binary => None
    }
    String(v) => Some(encode_string(v))
    Bytes(v) => Some(v)
  }
}

///|
fn encode_string(s : String) -> Bytes {
  @utf8.encode(s)
}

///|
/// Encode a `Value` into a `RawValue` for transmission to the server.
/// `Value::Null` becomes `RawValue::Null`. `Value::Bytes(_)` is sent in
/// binary format; everything else uses text format.
pub fn encode(v : Value) -> RawValue {
  match v {
    Null => RawValue::Null
    _ => {
      let format = match v {
        Bytes(_) => Format::Binary
        _ => Format::Text
      }
      match v.to_raw(format) {
        None => RawValue::Null
        Some(b) => RawValue::Bytes(format, b)
      }
    }
  }
}

///|
/// Types that can be used as SQL parameters.
pub(open) trait ToValue {
  fn to_value(Self) -> Value
}

///|
pub impl ToValue for Int with to_value(self) {
  Value::Int(self)
}

///|
pub impl ToValue for Int64 with to_value(self) {
  Value::Int64(self)
}

///|
pub impl ToValue for Double with to_value(self) {
  Value::Float(self)
}

///|
pub impl ToValue for String with to_value(self) {
  Value::String(self)
}

///|
pub impl ToValue for Bool with to_value(self) {
  Value::Bool(self)
}

///|
pub impl ToValue for Bytes with to_value(self) {
  Value::Bytes(self)
}

///|
pub impl[T : ToValue] ToValue for Option[T] with to_value(self) {
  match self {
    None => Value::Null
    Some(v) => v.to_value()
  }
}

///|
/// Types that can be decoded from a PostgreSQL cell value.
///
/// `from_value` receives a `Value` that was converted from the raw libpq
/// result (see `RawValue::to_value`). Implementations should handle:
///
/// * `Value::Null` — SQL NULL; raise or return a default
/// * `Value::String(s)` — text-format value
/// * `Value::Bytes(b)` — binary-format value (reserved for future support)
///
/// The basic implementations raise `PgError::QueryError` on `Null`; use
/// `Option[T]` for nullable columns.
pub(open) trait FromValue {
  fn from_value(Value) -> Self raise PgError
}

///|
pub fn[T] raise_null(label : String) -> T raise PgError {
  raise PgError::QueryError(
    "cannot decode NULL as \{label}; use Option[\{label}] for nullable columns",
  )
}

///|
pub fn[T] raise_binary() -> T raise PgError {
  raise PgError::QueryError(
    "binary-format cell values are not supported yet",
  )
}

///|
pub impl FromValue for Int with from_value(v : Value) raise PgError {
  match v {
    Null => raise_null("Int")
    String(s) =>
      try {
        @string.parse_int(s)
      } catch {
        _ => raise PgError::QueryError("cannot convert '\{s}' to Int")
      }
    Bytes(_) => raise_binary()
    _ => raise PgError::QueryError("unexpected value type for Int")
  }
}

///|
pub impl FromValue for Int64 with from_value(v : Value) raise PgError {
  match v {
    Null => raise_null("Int64")
    String(s) =>
      try {
        @string.parse_int64(s)
      } catch {
        _ => raise PgError::QueryError("cannot convert '\{s}' to Int64")
      }
    Bytes(_) => raise_binary()
    _ => raise PgError::QueryError("unexpected value type for Int64")
  }
}

///|
pub impl FromValue for Double with from_value(v : Value) raise PgError {
  match v {
    Null => raise_null("Double")
    String(s) =>
      try {
        @string.parse_double(s)
      } catch {
        _ => raise PgError::QueryError("cannot convert '\{s}' to Double")
      }
    Bytes(_) => raise_binary()
    _ => raise PgError::QueryError("unexpected value type for Double")
  }
}

///|
pub impl FromValue for Bool with from_value(v : Value) raise PgError {
  match v {
    Null => raise_null("Bool")
    String(s) =>
      try {
        @string.parse_bool(s)
      } catch {
        _ => raise PgError::QueryError("cannot convert '\{s}' to Bool")
      }
    Bytes(_) => raise_binary()
    _ => raise PgError::QueryError("unexpected value type for Bool")
  }
}

///|
pub impl FromValue for String with from_value(v : Value) raise PgError {
  match v {
    Null => raise_null("String")
    String(s) => s
    Bytes(_) => raise_binary()
    _ => raise PgError::QueryError("unexpected value type for String")
  }
}

///|
/// Nullable variant of `FromValue`: `SQL NULL` decodes to `None`, any other
/// value is delegated to `T::from_value` (which itself may raise).
pub impl[T : FromValue] FromValue for T? with from_value(v : Value) raise PgError {
  match v {
    Null => None
    String(s) => Some(T::from_value(Value::String(s)))
    Bytes(_) => raise_binary()
    _ => raise PgError::QueryError("unexpected value type for Option[T]")
  }
}

///|
/// Encode an array of `Value`s into `EncodedParams` for passing to the FFI
/// parameterized-query functions.
pub fn encode_params(params : Array[Value]) -> EncodedParams {
  let n = params.length()

  let values = FixedArray::make(n, Bytes::default())
  let lengths = FixedArray::make(n, 0)
  let formats = FixedArray::make(n, 0)
  let nulls = FixedArray::make(n, false)

  for i, param in params {
    let raw = encode(param)
    match raw {
      Null => {
        formats[i] = Format::Text.to_int()
        nulls[i] = true
      }
      Bytes(format, b) => {
        formats[i] = format.to_int()
        values[i] = b
        lengths[i] = b.length()
      }
    }
  }

  { values, lengths, formats, nulls }
}
