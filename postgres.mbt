///|
suberror PgError {
  ConnectionError(String)
  QueryError(String)
  NoRows
} derive(Debug)

///|
/// Wraps a libpq PGconn connection handle.
pub struct Connection {
  conn : @ffi.Connection
}

///|
/// Query result rows (for SELECT). Use `rows.iter()` to iterate.
pub struct Rows {
  res : @ffi.Result
}

///|
/// A single row from a query result. `Row` is a snapshot: its column values
/// are copied out of the libpq result at iteration time, so the returned
/// `Row` is self-contained and does not need to be freed (MoonBit is GC'd).
/// The underlying `Rows` must still be freed after iteration completes.
///
/// Get values by column index (`row.get[Int](0)`) or by column name
/// (`row.get_by_name[String]("title")`). The basic `FromValue` impls raise
/// on SQL NULL; use `Option[T]` for nullable columns.
pub struct Row {
  values : Array[RawValue]
  col_names : Array[String]
}

///|
/// Iterate over the rows of a query result. Each `next()` call materializes
/// one row's values out of the libpq result into a self-contained `Row`
/// snapshot. Returns the standard `Iter[Row]`, so it works directly with a
/// `for` loop and with all iterator combinators (`map`, `filter`, `fold`,
/// `to_array`, ...).
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
  let n_cols = col_names.length()
  let res = self.res
  let mut index = 0
  Iter::new(
    fn() -> Row? {
      if index < total {
        // Snapshot one row: read every column into a RawValue.
        let values : Array[RawValue] = []
        for col = 0; col < n_cols; col = col + 1 {
          if @ffi.moonpg_getisnull(res, index, col) > 0 {
            values.push(RawValue::Null)
          } else {
            let fmt_int = @ffi.moonpg_fformat(res, col)
            let format = if fmt_int == 0 { Format::Text } else { Format::Binary }
            let bytes = @ffi.moonpg_getvalue_bytes(res, index, col)
            values.push(RawValue::Bytes(format, bytes))
          }
        }
        let row = Row::{ values, col_names }
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
    let b = @ffi.moonpg_fname_bytes(self.res, i)
    let name = try @utf8.decode(b) catch { _ => b.to_unchecked_string() }
    ignore(cols.set(i, name))
  }
  cols
}

///|
/// Free the result memory. Must be called after use.
pub fn Rows::free(self : Rows) -> Unit {
  @ffi.moonpg_free_result(self.res)
}

///|
/// Read the value at column `col` (zero-based index) as `T`.
/// The stored `RawValue` is converted to `Value` via `to_value()`,
/// then `T::from_value` decodes it into the target type.
///
/// * For `Int`, `Int64`, `Double`, `Bool`, `String` — raises on `NULL`.
/// * For `Option[T : FromValue]` — returns `None` on `NULL`, otherwise
///   decodes the cell through `T::from_value`.
///
/// Raises `PgError::QueryError` if `T::from_value` fails to parse the value.
pub fn[T : FromValue] Row::get(self : Row, col : Int) -> T raise PgError {
  let raw = self.values[col]
  let val = raw.to_value()
  T::from_value(val)
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
/// Execution result (for INSERT/UPDATE/DELETE/DDL).
pub struct ExecResult {
  res : @ffi.Result
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
/// Open a new connection to a PostgreSQL server.
///
/// `conninfo` is a libpq-style connection string, e.g.
/// `"host=localhost port=5432 dbname=mydb user=postgres"`.
pub fn connect(conninfo : String) -> Connection raise PgError {
  let inner = @ffi.moonpg_connect(@utf8.encode(conninfo))
  if @ffi.moonpg_conn_is_null(inner) > 0 {
    raise PgError::ConnectionError("connection returned null")
  }
  let err = error_message_string(inner)
  if err.length() > 0 {
    @ffi.moonpg_close(inner)
    raise PgError::ConnectionError(err)
  }
  Connection::{ conn: inner }
}

///|
/// Close the database connection.
pub fn Connection::close(self : Connection) -> Unit {
  @ffi.moonpg_close(self.conn)
}

///|
/// Returns the last libpq error message, decoded from UTF-8 to a MoonBit
/// `String`. Falls back to unchecked conversion if the bytes aren't valid
/// UTF-8 (e.g. on a server with a non-UTF-8 client encoding) so callers
/// still get something to inspect.
fn error_message_string(conn : @ffi.Connection) -> String {
  let b = @ffi.moonpg_error_message_bytes(conn)
  try @utf8.decode(b) catch { _ => b.to_unchecked_string() }
}

///|
fn build_params(params : Array[&ToValue]) -> EncodedParams {
  let values : Array[Value] = []
  for v in params {
    values.push(v.to_value())
  }
  encode_params(values)
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
        raise PgError::QueryError(error_message_string(self.conn))
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
        raise PgError::QueryError(error_message_string(self.conn))
      }
      Rows::{ res: inner }
    }
  }
}

///|
/// Execute a SQL query that is expected to return exactly one row. Returns
/// the first materialized `Row` snapshot. If multiple rows match, only the
/// first is returned (no error). If the result is empty, raises
/// `PgError::NoRows` — a sentinel error analogous to Go's
/// `database/sql.ErrNoRows` so callers can distinguish "no result" from
/// "query failed".
///
/// The underlying `Rows` is freed before this returns, so the returned
/// `Row` is self-contained and does not need to be freed.
///
/// ```
/// let row = conn.query_one("SELECT name FROM users WHERE id = $1", params=[id])!
/// let name : String = row.get(0)
/// ignore(name)
/// ```
pub fn Connection::query_one(
  self : Connection,
  sql : String,
  params? : Array[&ToValue],
) -> Row raise PgError {
  let rows = self.query(sql, params?)
  defer rows.free()
  match rows.iter().next() {
    Some(row) => row
    None => raise NoRows
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
        raise PgError::QueryError(error_message_string(self.conn))
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
        raise PgError::QueryError(error_message_string(self.conn))
      }
      ExecResult::{ res: inner }
    }
  }
}

///|
/// Return the server version as an integer (e.g. 180004 for 18.0.4).
pub fn Connection::server_version(self : Connection) -> Int {
  @ffi.moonpg_server_version(self.conn)
}

///|
/// Read an environment variable (useful for defaults like PGHOST, PGPORT).
pub fn get_env(name : String) -> String {
  let b = @ffi.moonpg_get_env_bytes(@utf8.encode(name))
  try @utf8.decode(b) catch { _ => b.to_unchecked_string() }
}
