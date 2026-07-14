///|
pub(all) suberror PgError {
  ConnectionError(String)
  QueryError(String)
  NoRows
} derive(Debug)

///|
/// Connection status.
pub enum ConnStatus {
  OK
  Bad
} derive(Debug, Eq)

// ---------------------------------------------------------------------------
// Rows trait — polymorphic row iteration
// ---------------------------------------------------------------------------

///|
/// A pull-based row reader. Both `ConnRows` (bare connection) and
/// `PoolRows` (pooled connection) implement this trait.
///
/// ```moonbit
/// while rows.has_next() {
///   let row = rows.get_row()
///   let v : Int = row.get(0)
/// }
/// rows.close()
/// ```
pub(open) trait Rows {
  async fn has_next(Self) -> Bool raise PgError
  fn get_row(Self) -> Row raise PgError
  fn columns(Self) -> Array[@wire.FieldDescription]
  async fn close(Self) -> Unit raise PgError
}

// ---------------------------------------------------------------------------
// ConnRows — bare connection rows
// ---------------------------------------------------------------------------

///|
/// Rows from a bare `Connection`. Wraps a wire `ResultReader`.
pub(all) struct ConnRows {
  reader : @wire.ResultReader
}

///|
pub impl Rows for ConnRows with fn has_next(
  self : ConnRows,
) -> Bool raise PgError {
  self.reader.has_next() catch {
    e => raise map_wire_error(e)
  }
}

///|
pub impl Rows for ConnRows with fn get_row(
  self : ConnRows,
) -> Row raise PgError {
  let raw_row = self.reader.data_row() catch {
    e => raise map_wire_error(e)
  }
  let col_descs = self.reader.columns()
  let values : Array[RawValue] = []
  for i = 0; i < raw_row.length(); i = i + 1 {
    match raw_row[i] {
      None => values.push(RawValue::Null)
      Some(bytes) => {
        let format = if i < col_descs.length() && col_descs[i].format != 0 {
          Format::Binary
        } else {
          Format::Text
        }
        values.push(RawValue::Bytes(format, bytes))
      }
    }
  }
  Row::{ values, col_descs }
}

///|
pub impl Rows for ConnRows with fn columns(
  self : ConnRows,
) -> Array[@wire.FieldDescription] {
  self.reader.columns()
}

///|
/// Drain remaining results from the reader.
pub impl Rows for ConnRows with fn close(self : ConnRows) -> Unit raise PgError {
  let _ = self.reader.close() catch {
    e => raise map_wire_error(e)
  }
}

// ---------------------------------------------------------------------------
// Row — a single result row
// ---------------------------------------------------------------------------

///|
/// A single row from a query result.
pub struct Row {
  values : Array[RawValue]
  col_descs : Array[@wire.FieldDescription]
}

///|
/// Read the value at column `col` (zero-based index) as `T`.
pub fn[T : FromRaw] Row::get(self : Row, col : Int) -> T raise PgError {
  let raw = self.values[col]
  T::from_raw(raw)
}

///|
/// Read the value of column `name` as `T`.
pub fn[T : FromRaw] Row::get_by_name(
  self : Row,
  name : String,
) -> T raise PgError {
  for i = 0; i < self.col_descs.length(); i = i + 1 {
    if self.col_descs[i].name == name {
      return self.get(i)
    }
  }
  raise PgError::QueryError("column '\{name}' not found")
}

///|
/// Return the column descriptions of this row's result set.
pub fn Row::columns(self : Row) -> Array[@wire.FieldDescription] {
  self.col_descs
}

// ---------------------------------------------------------------------------
// ExecResult
// ---------------------------------------------------------------------------

///|
/// Execution result (for INSERT/UPDATE/DELETE/DDL).
pub struct ExecResult {
  tag : @wire.CommandTag
}

///|
/// Return the number of rows affected by an INSERT/UPDATE/DELETE.
pub fn ExecResult::affected_rows(self : ExecResult) -> Int {
  match self.tag.rows_affected() {
    Some(n) => n
    None => 0
  }
}

///|
/// Close the execution result. No-op.
pub fn ExecResult::close(_self : ExecResult) -> Unit {

}

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

///|
/// Wraps a wire-protocol `RawConn`.
pub struct Connection {
  conn : @wire.RawConn
}

///|
/// Open a new connection to a PostgreSQL server.
pub async fn connect(conninfo : String) -> Connection raise PgError {
  let inner = @wire.connect(conninfo) catch {
    e => raise map_wire_error(e)
  }
  Connection::{ conn: inner }
}

///|
/// Close the database connection.
pub fn Connection::close(self : Connection) -> Unit {
  self.conn.close()
}

///|
/// Return the server version as an integer (e.g. 180004 for 18.0.4).
pub fn Connection::server_version(self : Connection) -> Int {
  match self.conn.param(@wire.PARAM_SERVER_VERSION) {
    Some(v) => parse_server_version(v)
    None => 0
  }
}

///|
/// Return the current connection status.
pub fn Connection::status(self : Connection) -> ConnStatus {
  match self.conn.status() {
    @wire.Idle | @wire.Busy => ConnStatus::OK
    _ => ConnStatus::Bad
  }
}

// ---------------------------------------------------------------------------
// QueryExecutor trait
// ---------------------------------------------------------------------------

///|
/// Types that can execute SQL queries.
pub(open) trait QueryExecutor {
  async fn query(Self, String, params? : Array[&ToValue]) -> &Rows raise PgError
  async fn query_one(Self, String, params? : Array[&ToValue]) -> Row raise PgError
  async fn execute(Self, String, params? : Array[&ToValue]) -> ExecResult raise PgError
}

// ---------------------------------------------------------------------------
// Connection: QueryExecutor impl
// ---------------------------------------------------------------------------

///|
/// Execute a SQL query (SELECT) on a bare connection.
pub impl QueryExecutor for Connection with fn query(
  self : Connection,
  sql : String,
  params? : Array[&ToValue],
) -> &Rows raise PgError {
  match params {
    None => {
      let reader = self.conn.simple_query(sql) catch {
        e => raise map_wire_error(e)
      }
      ConnRows::{ reader }
    }
    Some(ps) => {
      let (vals, _) = build_param_arrays(ps)
      let reader = self.conn.execute_params(sql, vals, [], [], []) catch {
        e => raise map_wire_error(e)
      }
      ConnRows::{ reader }
    }
  }
}

///|
pub impl QueryExecutor for Connection with fn query_one(
  self : Connection,
  sql : String,
  params? : Array[&ToValue],
) -> Row raise PgError {
  let rows = self.query(sql, params?)
  if rows.has_next() {
    let row = rows.get_row()
    rows.close()
    return row
  }
  rows.close()
  raise NoRows
}

///|
pub impl QueryExecutor for Connection with fn execute(
  self : Connection,
  sql : String,
  params? : Array[&ToValue],
) -> ExecResult raise PgError {
  match params {
    None => {
      let reader = self.conn.simple_query(sql) catch {
        e => raise map_wire_error(e)
      }
      let tag = reader.close() catch {
        e => raise map_wire_error(e)
      }
      ExecResult::{ tag }
    }
    Some(ps) => {
      let (vals, _) = build_param_arrays(ps)
      let reader = self.conn.execute_params(sql, vals, [], [], []) catch {
        e => raise map_wire_error(e)
      }
      let tag = reader.close() catch {
        e => raise map_wire_error(e)
      }
      ExecResult::{ tag }
    }
  }
}

// ---------------------------------------------------------------------------
// internal helpers
// ---------------------------------------------------------------------------

///|
/// Map a `WireError` to a `PgError`.
fn map_wire_error(e : @wire.WireError) -> PgError {
  match e {
    @wire.PgServer(m) => PgError::QueryError(m)
    @wire.Connect(m) => PgError::ConnectionError(m)
    @wire.Auth(m) => PgError::ConnectionError(m)
    @wire.Parse(m) => PgError::ConnectionError(m)
    @wire.InvalidMessage(m) => PgError::QueryError(m)
    @wire.IO(m) => PgError::ConnectionError(m)
  }
}

///|
fn build_param_arrays(
  params : Array[&ToValue],
) -> (Array[Bytes?], Array[Int]) {
  let values : Array[Value] = []
  for v in params {
    values.push(v.to_value())
  }
  build_params(values)
}

///|
fn parse_server_version(s : String) -> Int {
  let parts = s.split(".")
  let mut result = 0
  let mut count = 0
  for part in parts {
    let n = @string.parse_int(part) catch { _ => 0 }
    match count {
      0 => result = n * 10000
      1 => result = result + n * 100
      2 => result = result + n
      _ => ()
    }
    count = count + 1
  }
  result
}

///|
/// Read an environment variable.
pub fn get_env(name : String) -> String {
  match @env.get_env_var(name) {
    Some(v) => v
    None => ""
  }
}
