///|
suberror PgError {
  ConnectionError(String)
  QueryError(String)
} derive(Debug)

///|
pub type Value = @ffi.Value

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
/// The basic implementations (`Int`, `Int64`, `Double`, `Bool`, `String`)
/// decode the text-mode bytes returned by libpq and raise
/// `PgError::QueryError` when the cell is SQL NULL — for nullable columns,
/// use the `Option[T]` impl instead, which handles `Null` automatically.
///
/// `FromValue for Bytes` is intentionally not provided yet: the
/// `RawValue::Bytes` case will currently raise on the basic impls. Use the
/// lower-level `@ffi.moonpg_getvalue_bytes` directly to read raw bytes.
pub(open) trait FromValue {
  fn from_value(@ffi.RawValue) -> Self raise PgError
}

///|
fn raise_null[T](label : String) -> T raise PgError {
  raise PgError::QueryError(
    "cannot decode NULL as \{label}; use Option[\{label}] for nullable columns",
  )
}

///|
fn decode_text(b : Bytes, _label : String) -> String {
  // PG text-mode results are UTF-8 bytes. Decode them as UTF-8 so the
  // resulting String holds the correct codepoints. If decoding fails for
  // some reason, fall back to unchecked conversion so callers still get
  // something to inspect / fail on.
  try {
    @utf8.decode(b)
  } catch {
    _ => b.to_unchecked_string()
  }
}

///|
pub impl FromValue for Int with from_value(rv : @ffi.RawValue) raise PgError {
  match rv {
    Null => raise_null("Int")
    Bytes(b) =>
      try {
        @string.parse_int(decode_text(b, "Int"))
      } catch {
        _ =>
          raise PgError::QueryError(
            "cannot convert '\{decode_text(b, "Int")}' to Int",
          )
      }
  }
}

///|
pub impl FromValue for Int64 with from_value(rv : @ffi.RawValue) raise PgError {
  match rv {
    Null => raise_null("Int64")
    Bytes(b) =>
      try {
        @string.parse_int64(decode_text(b, "Int64"))
      } catch {
        _ =>
          raise PgError::QueryError(
            "cannot convert '\{decode_text(b, "Int64")}' to Int64",
          )
      }
  }
}

///|
pub impl FromValue for Double with from_value(rv : @ffi.RawValue) raise PgError {
  match rv {
    Null => raise_null("Double")
    Bytes(b) =>
      try {
        @string.parse_double(decode_text(b, "Double"))
      } catch {
        _ =>
          raise PgError::QueryError(
            "cannot convert '\{decode_text(b, "Double")}' to Double",
          )
      }
  }
}

///|
pub impl FromValue for Bool with from_value(rv : @ffi.RawValue) raise PgError {
  match rv {
    Null => raise_null("Bool")
    Bytes(b) =>
      try {
        @string.parse_bool(decode_text(b, "Bool"))
      } catch {
        _ =>
          raise PgError::QueryError(
            "cannot convert '\{decode_text(b, "Bool")}' to Bool",
          )
      }
  }
}

///|
pub impl FromValue for String with from_value(rv : @ffi.RawValue) raise PgError {
  match rv {
    Null => raise_null("String")
    Bytes(b) => decode_text(b, "String")
  }
}

///|
/// Nullable variant of `FromValue`: `SQL NULL` decodes to `None`, any other
/// value is delegated to `T::from_value` (which itself may raise).
pub impl[T : FromValue] FromValue for T? with from_value(rv : @ffi.RawValue) raise PgError {
  match rv {
    Null => None
    Bytes(b) => Some(T::from_value(@ffi.RawValue::Bytes(b)))
  }
}


///|
/// Wraps a libpq PGconn connection handle.
pub struct Connection {
  conn : @ffi.Connection
}

///|
/// Query result rows (for SELECT). Use `rows.iter()` to iterate, or
/// `rows.rows()` to materialize all rows at once.
pub struct Rows {
  res : @ffi.Result
}

///|
/// A single row from a query result. Get values by column index
/// (`row.get[Int](0)`) or by column name (`row.get_by_name[String]("title")`).
/// Both methods return `None` when the column is SQL NULL.
pub struct Row {
  res : @ffi.Result
  row_index : Int
  col_names : Array[String]
}

///|
/// Execution result (for INSERT/UPDATE/DELETE/DDL).
pub struct ExecResult {
  res : @ffi.Result
}

///|
/// Open a new connection to a PostgreSQL server.
///
/// `conninfo` is a libpq-style connection string, e.g.
/// `"host=localhost port=5432 dbname=mydb user=postgres"`.
pub fn connect(conninfo : String) -> Connection raise PgError {
  let inner = @ffi.moonpg_connect(@utf8.encode(conninfo))
  if @ffi.moonpg_conn_is_null(inner) > 0 {
    raise PgError::ConnectionError("connection returned null")
  }
  let err = @ffi.moonpg_error_message(inner)
  if err.length() > 0 {
    @ffi.moonpg_close(inner)
    raise PgError::ConnectionError(err)
  }
  Connection::{ conn: inner }
}

///|
fn build_params(params : Array[&ToValue]) -> @ffi.EncodedParams {
  let values : Array[Value] = []
  for v in params {
    values.push(v.to_value())
  }
  @ffi.encode_params(values)
}

///|
/// Execute a SQL query (SELECT). Omit `params` for direct PQexec; pass
/// `params=[...]` for PQexecParams. Pass an `Array[&ToValue]` so each
/// element can be a different `T : ToValue`.
pub fn Connection::query(
  self : Connection,
  sql : String,
  params? : Array[&ToValue],
) -> Rows raise PgError {
  match params {
    None => {
      let inner = @ffi.moonpg_query(self.conn, @utf8.encode(sql))
      if @ffi.moonpg_result_is_null(inner) > 0 {
        raise PgError::QueryError(@ffi.moonpg_error_message(self.conn))
      }
      Rows::{ res: inner }
    }
    Some(ps) => {
      let p = build_params(ps)
      let inner = @ffi.moonpg_query_params(
        self.conn,
        @utf8.encode(sql),
        ps.length(),
        p.values,
        p.lengths,
        p.formats,
        p.nulls,
      )
      if @ffi.moonpg_result_is_null(inner) > 0 {
        raise PgError::QueryError(@ffi.moonpg_error_message(self.conn))
      }
      Rows::{ res: inner }
    }
  }
}

///|
/// Execute a SQL command (INSERT/UPDATE/DELETE/DDL). Omit `params` for direct
/// PQexec; pass `params=[...]` for PQexecParams. Pass an `Array[&ToValue]`
/// so each element can be a different `T : ToValue`.
pub fn Connection::execute(
  self : Connection,
  sql : String,
  params? : Array[&ToValue],
) -> ExecResult raise PgError {
  match params {
    None => {
      let inner = @ffi.moonpg_execute(self.conn, @utf8.encode(sql))
      if @ffi.moonpg_result_is_null(inner) > 0 {
        raise PgError::QueryError(@ffi.moonpg_error_message(self.conn))
      }
      ExecResult::{ res: inner }
    }
    Some(ps) => {
      let p = build_params(ps)
      let inner = @ffi.moonpg_execute_params(
        self.conn,
        @utf8.encode(sql),
        ps.length(),
        p.values,
        p.lengths,
        p.formats,
        p.nulls,
      )
      if @ffi.moonpg_result_is_null(inner) > 0 {
        raise PgError::QueryError(@ffi.moonpg_error_message(self.conn))
      }
      ExecResult::{ res: inner }
    }
  }
}

///|
/// Iterate over the rows of a query result. Returns the standard
/// `Iter[Row]`, so it works directly with a `for` loop and with all iterator
/// combinators (`map`, `filter`, `fold`, `to_array`, ...).
///
/// ```
/// let rows = conn.query("SELECT id, name FROM users")!
/// for row in rows.iter() {
///   let id : Int = row.get(0)
///   let name : Option[String] = row.get_by_name("name")
///   ignore(id); ignore(name)
/// }
/// rows.free()
/// ```
pub fn Rows::iter(self : Rows) -> Iter[Row] {
  let total = @ffi.moonpg_ntuples(self.res)
  let col_names = self.columns()
  let res = self.res
  let mut index = 0
  Iter::new(
    fn() -> Row? {
      if index < total {
        let row = Row::{ res, row_index: index, col_names }
        index += 1
        Some(row)
      } else {
        None
      }
    },
    size_hint=total,
  )
}
///|
/// Return the column names of the result.
pub fn Rows::columns(self : Rows) -> Array[String] {
  let n_cols = @ffi.moonpg_nfields(self.res)
  let cols = Array::make(n_cols, "")
  for i = 0; i < n_cols; i = i + 1 {
    let name = @ffi.moonpg_fname(self.res, i)
    ignore(cols.set(i, name))
  }
  cols
}

///|
/// Return the number of rows affected (for INSERT/UPDATE/DELETE).
pub fn Rows::affected_rows(self : Rows) -> Int {
  @ffi.moonpg_cmdtuples(self.res).to_int()
}

///|
/// Return all rows as an `Array[Array[String]]` of text values. This is a
/// convenience helper for callers that don't need typed decoding.
pub fn Rows::rows(self : Rows) -> Array[Array[String]] {
  let n_rows = @ffi.moonpg_ntuples(self.res)
  let n_cols = @ffi.moonpg_nfields(self.res)
  let row_arrays = Array::make(n_rows, Array::make(n_cols, ""))
  for i = 0; i < n_rows; i = i + 1 {
    let row_arr = Array::make(n_cols, "")
    for j = 0; j < n_cols; j = j + 1 {
      let val = @ffi.moonpg_getvalue(self.res, i, j)
      ignore(row_arr.set(j, val))
    }
    ignore(row_arrays.set(i, row_arr))
  }
  row_arrays
}

///|
/// Free the result memory. Must be called after use.
pub fn Rows::free(self : Rows) -> Unit {
  @ffi.moonpg_free_result(self.res)
}

///|
/// Read the value at column `col` (zero-based index) as `T`. The `RawValue` is
/// fed to `T::from_value`, which decodes the cell and decides what to do with
/// `NULL`:
///
/// * For `Int`, `Int64`, `Double`, `Bool`, `String` — raises on `NULL`.
/// * For `Option[T : FromValue]` — returns `None` on `NULL`, otherwise decodes
///   the cell through `T::from_value`.
///
/// Raises `PgError::QueryError` if `T::from_value` fails to parse the value.
pub fn[T : FromValue] Row::get(self : Row, col : Int) -> T raise PgError {
  let rv = if @ffi.moonpg_getisnull(self.res, self.row_index, col) > 0 {
    @ffi.RawValue::Null
  } else {
    @ffi.RawValue::Bytes(@ffi.moonpg_getvalue_bytes(self.res, self.row_index, col))
  }
  T::from_value(rv)
}

///|
/// Read the value of column `name` as `T`. See `Row::get` for the decoding
/// rules. Raises `PgError::QueryError` if the column does not exist or if
/// `T::from_value` fails to parse the value.
pub fn[T : FromValue] Row::get_by_name(self : Row, name : String) -> T raise PgError {
  for i = 0; i < self.col_names.length(); i = i + 1 {
    if self.col_names[i] == name {
      return self.get(i)
    }
  }
  raise PgError::QueryError("column '\{name}' not found")
}

///|
/// Return the column names of this row's result set.
pub fn Row::columns(self : Row) -> Array[String] {
  self.col_names
}

///|
/// Return the number of rows affected by an INSERT/UPDATE/DELETE.
pub fn ExecResult::affected_rows(self : ExecResult) -> Int {
  @ffi.moonpg_cmdtuples(self.res).to_int()
}

///|
/// Free the result memory. Must be called after use.
pub fn ExecResult::free(self : ExecResult) -> Unit {
  @ffi.moonpg_free_result(self.res)
}

///|
/// Close the database connection.
pub fn Connection::close(self : Connection) -> Unit {
  @ffi.moonpg_close(self.conn)
}

///|
/// Return the server version as an integer (e.g. 180004 for 18.0.4).
pub fn Connection::server_version(self : Connection) -> Int {
  @ffi.moonpg_server_version(self.conn)
}

///|
/// Read an environment variable (useful for defaults like PGHOST, PGPORT).
pub fn get_env(name : String) -> String {
  @ffi.moonpg_get_env(@utf8.encode(name))
}