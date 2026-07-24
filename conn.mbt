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
/// ```moonbit nocheck
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
pub impl Rows for ConnRows with fn has_next(self : ConnRows) -> Bool raise PgError {
  self.reader.has_next() catch {
    e => raise map_wire_error(e)
  }
}

///|
pub impl Rows for ConnRows with fn get_row(self : ConnRows) -> Row raise PgError {
  let raw_row = self.reader.data_row() catch { e => raise map_wire_error(e) }
  let col_descs = self.reader.columns()
  Row::{ values: raw_row, col_descs }
}

///|
pub impl Rows for ConnRows with fn columns(self : ConnRows) -> Array[
  @wire.FieldDescription,
] {
  self.reader.columns()
}

///|
/// Drain remaining results from the reader.
pub impl Rows for ConnRows with fn close(self : ConnRows) -> Unit raise PgError {
  let _ = self.reader.close() catch { e => raise map_wire_error(e) }
}

// ---------------------------------------------------------------------------
// Row — a single result row
// ---------------------------------------------------------------------------

///|
/// A single row from a query result.
pub struct Row {
  values : Array[Bytes?]
  col_descs : Array[@wire.FieldDescription]
}

///|
/// Read the value at column `col` (zero-based index) as `T`.
pub fn[T : @value.FromValue] Row::get(self : Row, col : Int) -> T raise PgError {
  let desc = self.col_descs[col]
  let format = if desc.format == 0 {
    @value.Format::Text
  } else {
    @value.Format::Binary
  }
  let codec = @pgtype.default_map.codec_for(desc.type_oid)
  let val = codec.decode(desc.type_oid, format, self.values[col]) catch {
    e => {
      let msg = match e {
        @pgtype.CodecError::CodecError(m) => m
      }
      raise PgError::QueryError("codec decode error: \{msg}")
    }
  }
  T::from_value(val) catch {
    e => {
      let msg = match e {
        @value.ValueError::ValueError(m) => m
      }
      raise PgError::QueryError("from_value error: \{msg}")
    }
  }
}

///|
/// Read the value of column `name` as `T`.
pub fn[T : @value.FromValue] Row::get_by_name(
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
  let inner = @wire.connect(conninfo) catch { e => raise map_wire_error(e) }
  Connection::{ conn: inner }
}

///|
/// Close the database connection.
pub fn Connection::close(self : Connection) -> Unit {
  self.conn.close()
}

///|
/// Return the backend process ID assigned by PostgreSQL.
pub fn Connection::backend_pid(self : Connection) -> Int {
  self.conn.backend_pid()
}

///|
/// Return a server parameter value (e.g. `"server_version"`, `"TimeZone"`).
///
/// Returns `None` if the parameter was not reported by the server during
/// startup.
pub fn Connection::param(self : Connection, key : String) -> String? {
  self.conn.param(key)
}

///|
/// Return `true` if the connection has been closed.
pub fn Connection::is_closed(self : Connection) -> Bool {
  self.conn.is_closed()
}

///|
/// Deallocate a prepared statement.
///
/// Sends `Close(S)` + `Flush` and waits for `CloseComplete`.  Returns
/// silently on success — raises `PgError` if the statement doesn't exist
/// or the connection is broken.
///
/// Passing an empty string closes the unnamed statement.
pub async fn Connection::deallocate(
  self : Connection,
  name : String,
) -> Unit raise PgError {
  self.conn.close_statement(name) catch {
    e => raise map_wire_error(e)
  }
}

// ---------------------------------------------------------------------------
// Listener — async notification receiver
// ---------------------------------------------------------------------------

///|
/// Receiver for PostgreSQL notifications.
///
/// Created by `Connection::listen`.  Call `recv()` to block until a
/// notification arrives.
pub(all) struct Listener {
  q : @aqueue.Queue[@wire.NotificationResponse]
}

///|
/// Block until a notification arrives.
pub async fn Listener::recv(
  self : Listener,
) -> @wire.NotificationResponse raise PgError {
  self.q.get() catch {
    _ => raise PgError::ConnectionError("listen connection closed")
  }
}

///|
/// Start listening for notifications on the given channel.
///
/// Executes `LISTEN channel`, spawns a background receive loop on `group`,
/// and returns a `Listener`.  The connection is dedicated to listening.
///
/// ```moonbit nocheck
/// @async.with_task_group() <| group => {
///   let listener = conn.listen("events", group)
///   for ;; {
///     let notif = listener.recv()
///     group.spawn_bg() <| () => { handle(notif) }
///   }
/// }
/// ```
pub async fn[X] Connection::listen(
  self : Connection,
  channel : String,
  group : @async.TaskGroup[X],
) -> Listener raise PgError {
  self.execute("LISTEN " + channel) |> ignore
  let q = @aqueue.Queue(kind=@aqueue.Unbounded)
  let conn = self.conn

  group.spawn_loop(no_wait=false) <| () => {
    let msg = conn.receive() catch { _ => raise @async.BreakFromSpawnLoop }
    match msg {
      @wire.NotificationResponse(n) => ignore(q.try_put(n) catch { _ => false })
      _ => ()
    }
  }

  Listener::{ q, }
}

///|
/// Stop listening for notifications on the given channel.
///
/// Passing `"*"` unlistens from all channels.
pub async fn Connection::unlisten(
  self : Connection,
  channel : String,
) -> Unit raise PgError {
  let _ = self.execute("UNLISTEN " + channel)
}

///|
/// Send a notification on the given channel.
///
/// An optional `payload` string can be included.
pub async fn Connection::notify(
  self : Connection,
  channel : String,
  payload? : String,
) -> Unit raise PgError {
  match payload {
    None => {
      let _ = self.execute("NOTIFY " + channel)
    }
    Some(p) => {
      let _ = self.execute("NOTIFY " + channel + ", '" + p + "'")
    }
  }
}

///|
/// Execute `COPY ... FROM STDIN` with rows from an iterator.
///
/// Each element is one line of COPY data (tab-separated, newline-terminated).
/// Rows are pulled one at a time — only a single row is held in memory.
///
/// ```moonbit nocheck
/// conn.copy_in("COPY t FROM STDIN", my_rows.iter())
/// ```
pub async fn Connection::copy_in(
  self : Connection,
  sql : String,
  rows : Iter[String],
) -> ExecResult raise PgError {
  self.conn.copy_in(sql, rows) catch {
    e => raise map_wire_error(e)
  }
  ExecResult::{ tag: @wire.CommandTag::new("COPY 0") }
}

// ---------------------------------------------------------------------------
// Streaming COPY writer
// ---------------------------------------------------------------------------

///|
/// Streaming writer for `COPY ... FROM STDIN`.
///
/// Created via `Connection::begin_copy`.  Rows are encoded and sent one at
/// a time — only a single row is held in memory.
///
/// # Example
/// ```
/// let w = conn.begin_copy("users", ["name", "age"])
/// w.write_row(["Alice", 30])
/// w.write_row(["Bob", 25])
/// let result = w.finish()
/// ```
pub(all) struct CopyWriter {
  conn : @wire.RawConn
}

///|
/// Begin a `COPY ... FROM STDIN` operation on the given table and columns.
///
/// Generates `COPY table ("col1", "col2") FROM STDIN`, sends the query,
/// and returns a `CopyWriter` that accepts rows one at a time.
pub async fn Connection::begin_copy(
  self : Connection,
  table : String,
  columns : Array[String],
) -> CopyWriter raise PgError {
  let col_strs : Array[String] = []
  for col in columns {
    col_strs.push("\"" + col + "\"")
  }
  let sql = "COPY " + table + " (" + col_strs.join(", ") + ") FROM STDIN"
  self.conn.begin_copy_in(sql) catch {
    e => raise map_wire_error(e)
  }
  CopyWriter::{ conn: self.conn }
}

///|
/// Write a single row to the COPY stream.
///
/// Each value is encoded to COPY text format (tab-separated, `\N` for NULL,
/// backslash-escaped strings) and sent immediately — no batching in memory.
pub async fn CopyWriter::write_row(
  self : CopyWriter,
  row : Array[&@value.ToValue],
) -> Unit raise PgError {
  let parts : Array[String] = []
  for v in row {
    parts.push(encode_copy_text(v.to_value()))
  }
  let line = parts.join("\t") + "\n"
  self.conn.send_copy_data(@utf8.encode(line)) catch {
    e => raise map_wire_error(e)
  }
}

///|
/// Finish the COPY operation.
///
/// Sends `CopyDone`, reads the server completion, and returns the `ExecResult`.
pub async fn CopyWriter::finish(self : CopyWriter) -> ExecResult raise PgError {
  self.conn.end_copy_in() catch {
    e => raise map_wire_error(e)
  }
  ExecResult::{ tag: @wire.CommandTag::new("COPY") }
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
// exec_params — prepare, encode, execute
// ---------------------------------------------------------------------------

///|
/// Prepare a parameterised statement, encode parameters with codecs
/// using the OIDs returned by the server, and execute.
async fn exec_params(
  conn : @wire.RawConn,
  sql : String,
  params : Array[&@value.ToValue],
) -> @wire.ResultReader raise @wire.WireError {
  let stmt = conn.prepare("", sql, [])
  let n = params.length()
  let param_values : Array[Bytes?] = Array::makei(n, fn(_) { None })
  let param_formats : Array[Int] = Array::makei(n, fn(_) { 0 })
  for i = 0; i < n; i = i + 1 {
    let oid = stmt.param_oids[i]
    let codec = @pgtype.default_map.codec_for(oid)
    let val = params[i].to_value()
    let fmt = codec.prefer_format()
    param_values[i] = codec.encode(oid, fmt, val) catch {
      e => {
        let err_msg = match e {
          @pgtype.CodecError::CodecError(m) => m
        }
        raise @wire.WireError::InvalidMessage(
          "codec encode error for param \{i}: \{err_msg}",
        )
      }
    }
    param_formats[i] = if fmt == @value.Format::Binary { 1 } else { 0 }
  }
  let fields : Array[@wire.FieldDescription] = Array::makei(
    stmt.fields.length(),
    fn(i) {
      let f = stmt.fields[i]
      let codec = @pgtype.default_map.codec_for(f.type_oid)
      @wire.FieldDescription::{
        ..f,
        format: if codec.prefer_format() == @value.Format::Binary {
          1
        } else {
          0
        },
      }
    },
  )
  let stmt2 = @wire.StatementDescription::{
    name: stmt.name,
    sql: stmt.sql,
    param_oids: stmt.param_oids,
    fields,
  }
  conn.execute_statement(stmt2, param_values, param_formats)
}

// ---------------------------------------------------------------------------
// QueryExecutor trait
// ---------------------------------------------------------------------------

///|
/// Types that can execute SQL queries.
pub(open) trait QueryExecutor {
  async fn query(Self, String, params? : Array[&@value.ToValue]) -> &Rows raise PgError
  async fn query_one(Self, String, params? : Array[&@value.ToValue]) -> Row raise PgError
  async fn execute(Self, String, params? : Array[&@value.ToValue]) -> ExecResult raise PgError
}

// ---------------------------------------------------------------------------
// Connection: QueryExecutor impl
// ---------------------------------------------------------------------------

///|
/// Execute a SQL query (SELECT) on a bare connection.
pub impl QueryExecutor for Connection with fn query(
  self : Connection,
  sql : String,
  params? : Array[&@value.ToValue],
) -> &Rows raise PgError {
  match params {
    None => {
      let reader = self.conn.simple_query(sql) catch {
        e => raise map_wire_error(e)
      }
      ConnRows::{ reader, }
    }
    Some(ps) => {
      let reader = exec_params(self.conn, sql, ps) catch {
        e => raise map_wire_error(e)
      }
      ConnRows::{ reader, }
    }
  }
}

///|
pub impl QueryExecutor for Connection with fn query_one(
  self : Connection,
  sql : String,
  params? : Array[&@value.ToValue],
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
  params? : Array[&@value.ToValue],
) -> ExecResult raise PgError {
  match params {
    None => {
      let reader = self.conn.simple_query(sql) catch {
        e => raise map_wire_error(e)
      }
      let tag = reader.close() catch { e => raise map_wire_error(e) }
      ExecResult::{ tag, }
    }
    Some(ps) => {
      let reader = exec_params(self.conn, sql, ps) catch {
        e => raise map_wire_error(e)
      }
      let tag = reader.close() catch { e => raise map_wire_error(e) }
      ExecResult::{ tag, }
    }
  }
}

///|
/// Build a `Row` from raw wire data and column descriptions, respecting the
/// format code in each column.  Used by integration tests that request
/// binary result format.
pub fn row_from_raw(
  raw_row : Array[Bytes?],
  col_descs : Array[@wire.FieldDescription],
) -> Row {
  Row::{ values: raw_row, col_descs }
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
/// Encode a `Value` to PostgreSQL COPY text format.
///
/// * `Null` → `\N`
/// * `Bool` → `t` / `f`
/// * Numbers → decimal string
/// * `String` → backslash-escaped (\\, \t, \n)
/// * `Bytes` → hex-encoded (e.g. `\xDEADBEEF`)
fn encode_copy_text(v : @value.Value) -> String {
  match v {
    @value.Value::Null => "\\N"
    @value.Value::Bool(v) => if v { "t" } else { "f" }
    @value.Value::Int(v) => v.to_string()
    @value.Value::Int64(v) => v.to_string()
    @value.Value::Float(v) => v.to_string()
    @value.Value::String(v) => escape_copy_string(v)
    @value.Value::Bytes(v) => "\\\\x" + encode_hex(v)
    @value.Value::Timestamp(u) => u.to_string()
    @value.Value::Json(j) => escape_copy_string(j.stringify())
  }
}

///|
/// Escape special characters for COPY text format:
/// `\` → `\\`, tab → `\t`, newline → `\n`.
fn escape_copy_string(s : String) -> String {
  let mut result = ""
  for ch in s {
    if ch == '\\' {
      result = result + "\\\\"
    } else if ch == '\t' {
      result = result + "\\t"
    } else if ch == '\n' {
      result = result + "\\n"
    } else if ch == '\r' {
      result = result + "\\r"
    } else {
      result = result + ch.to_string()
    }
  }
  result
}

///|
/// Hex-encode bytes to a string (no prefix).
fn encode_hex(data : Bytes) -> String {
  let hex_digits = [
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F",
  ]
  let mut result = ""
  for i = 0; i < data.length(); i = i + 1 {
    let byte = data[i].to_int()
    result = result + hex_digits[(byte >> 4) & 0xF]
    result = result + hex_digits[byte & 0xF]
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
