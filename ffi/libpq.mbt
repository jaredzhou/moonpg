///|
#external
type Connection

///|
#external
type Result

///|
/// PostgreSQL parameter value.
pub(all) enum Value {
  Null
  Bool(Bool)
  Int(Int)
  Int64(Int64)
  Float(Double)
  String(String)
  Bytes(Bytes)
}

///|
/// Raw value read from a result cell.
///
/// * `Null` — the cell is SQL NULL.
/// * `String(s)` — the cell's text-format content, already decoded from the
///   connection's text-mode encoding (UTF-8 on a default UTF-8 cluster).
///   This is what `Row::get` produces today.
/// * `Bytes(b)` — reserved for future binary-format support. The current
///   `FromValue` impls raise on this variant.
pub(all) enum RawValue {
  Null
  String(String)
  Bytes(Bytes)
}

///|
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

   
 pub(all) enum Format {
  Text
  Binary
}  

fn to_int(f : Format) -> Int {
  match f {
    Text => 0
    Binary => 1
  }
}
///|
pub fn Value::to_binary(self : Value) -> Bytes? {
  match self {
    Null => None
    Bool(v) => {
      let buf : @buffer.Buffer = Buffer()

      buf.write_byte(if v { 1 } else { 0 })

      Some(buf.to_bytes())
    }
    Int(v) => Some(encode_i32(v))
    Int64(v) => Some(encode_i64(v))
    Float(v) => Some(b"float")
    String(v) => Some(encode_string(v))
    Bytes(v) => Some(v)
  }
}

///|
fn encode_string(s : String) -> Bytes {
  @utf8.encode(s)
}

///|
pub fn Value::to_text(self : Value) -> Bytes? {
  match self {
    Null => None
    Bool(v) => Some(encode_string(if v { "t" } else { "f" }))
    Int(v) => Some(encode_string(v.to_string()))
    Int64(v) => Some(encode_string(v.to_string()))
    Float(v) => Some(encode_string(v.to_string()))
    String(v) => Some(encode_string(v))
    Bytes(v) => Some(v)
  }
}

///|
pub fn encode(v : Value) -> (Format, Bytes?) {
  match v {
    Null => (Text, None)
    Bytes(_) => (Binary, v.to_binary())
    _ => (Text, v.to_text())
  }
}

///|
pub fn encode_params(params : Array[Value]) -> EncodedParams {
  let n = params.length()

  let values = FixedArray::make(n, Bytes::default())
  let lengths = FixedArray::make(n, 0)
  let formats = FixedArray::make(n, 0)
  let nulls = FixedArray::make(n, false)

  for i, param in params {
    let (format, bytes) = encode(param)

    formats[i] = to_int(format)

    match bytes {
      None => nulls[i] = true
      Some(b) => {
        values[i] = b
        lengths[i] = b.length()
      }
    }
  }

  { values, lengths, formats, nulls }
}

///|
#borrow(conninfo)
pub extern "C" fn moonpg_connect(conninfo : Bytes) -> Connection = "moonpg_connect"

///|
#borrow(conn, sql)
pub extern "C" fn moonpg_query(conn : Connection, sql : Bytes) -> Result = "moonpg_query"

///|
#owned(conn)
pub extern "C" fn moonpg_close(conn : Connection) -> Unit = "moonpg_close"

///|
#borrow(conn)
pub extern "C" fn moonpg_error_message_bytes(conn : Connection) -> Bytes = "moonpg_error_message_bytes"

///|
/// Returns the last libpq error message, decoded from UTF-8 to a MoonBit
/// `String`. Falls back to unchecked conversion if the bytes aren't valid
/// UTF-8 (e.g. on a server with a non-UTF-8 client encoding) so callers
/// still get something to inspect.
pub fn error_message_string(conn : Connection) -> String {
  let b = moonpg_error_message_bytes(conn)
  try @utf8.decode(b) catch {
    _ => b.to_unchecked_string()
  }
}

///|
#borrow(result)
pub extern "C" fn moonpg_ntuples(result : Result) -> Int = "moonpg_ntuples"

///|
#borrow(result)
pub extern "C" fn moonpg_nfields(result : Result) -> Int = "moonpg_nfields"

///|
#borrow(result)
pub extern "C" fn moonpg_getvalue(
  result : Result,
  row : Int,
  col : Int,
) -> String = "moonpg_getvalue"

///|
/// Returns the raw bytes of the cell. Caller should check
/// `moonpg_getisnull` first; an empty `Bytes` is returned for a NULL cell.
#borrow(result)
pub extern "C" fn moonpg_getvalue_bytes(
  result : Result,
  row : Int,
  col : Int,
) -> Bytes = "moonpg_getvalue_bytes"

///|
/// Returns the text-format cell value at `(row, col)`, decoded from UTF-8
/// to a MoonBit `String`. Falls back to unchecked conversion on invalid
/// UTF-8. Caller should check `moonpg_getisnull` first; an empty string is
/// returned for a NULL cell.
pub fn getvalue_string(result : Result, row : Int, col : Int) -> String {
  let b = moonpg_getvalue_bytes(result, row, col)
  try @utf8.decode(b) catch {
    _ => b.to_unchecked_string()
  }
}

///|
#borrow(result)
pub extern "C" fn moonpg_fname_bytes(result : Result, col : Int) -> Bytes = "moonpg_fname_bytes"

///|
/// Returns the column name at `col`, decoded from UTF-8 to a MoonBit
/// `String`. Falls back to unchecked conversion on invalid UTF-8.
pub fn fname_string(result : Result, col : Int) -> String {
  let b = moonpg_fname_bytes(result, col)
  try @utf8.decode(b) catch {
    _ => b.to_unchecked_string()
  }
}

///|
#borrow(result)
pub extern "C" fn moonpg_getisnull(
  result : Result,
  row : Int,
  col : Int,
) -> Int = "moonpg_getisnull"

///|
#borrow(result)
pub extern "C" fn moonpg_cmdtuples(result : Result) -> Int64 = "moonpg_cmdtuples"

///|
#owned(result)
pub extern "C" fn moonpg_free_result(result : Result) -> Unit = "moonpg_free_result"

///|
#borrow(conn)
pub extern "C" fn moonpg_conn_is_null(conn : Connection) -> Int = "moonpg_conn_is_null"

///|
#borrow(result)
pub extern "C" fn moonpg_result_is_null(result : Result) -> Int = "moonpg_result_is_null"

///|
#borrow(name)
pub extern "C" fn moonpg_get_env_bytes(name : Bytes) -> Bytes = "moonpg_get_env_bytes"

///|
/// Reads the environment variable `name` and decodes its value from UTF-8
/// to a MoonBit `String`. Returns an empty string if the variable is unset.
/// Falls back to unchecked conversion on invalid UTF-8.
pub fn get_env_string(name : Bytes) -> String {
  let b = moonpg_get_env_bytes(name)
  try @utf8.decode(b) catch {
    _ => b.to_unchecked_string()
  }
}

///|
#borrow(conn)
pub extern "C" fn moonpg_server_version(conn : Connection) -> Int = "moonpg_server_version"

///|
#borrow(conn, sql)
pub extern "C" fn moonpg_execute(conn : Connection, sql : Bytes) -> Result = "moonpg_execute"

///|
#borrow(conn)
pub extern "C" fn moonpg_status(conn : Connection) -> Int = "moonpg_status"

///|
#borrow(conn, sql, values, lengths, formats, nulls)
pub extern "C" fn moonpg_query_params(
  conn : Connection,
  sql : Bytes,
  param_counts : Int,
  values : FixedArray[Bytes],
  lengths : FixedArray[Int],
  formats : FixedArray[Int],
  nulls : FixedArray[Bool],
) -> Result = "moonpg_query_params"

///|
#borrow(conn, sql, values, lengths, formats, nulls)
pub extern "C" fn moonpg_execute_params(
  conn : Connection,
  sql : Bytes,
  param_counts : Int,
  values : FixedArray[Bytes],
  lengths : FixedArray[Int],
  formats : FixedArray[Int],
  nulls : FixedArray[Bool],
) -> Result = "moonpg_execute_params"
