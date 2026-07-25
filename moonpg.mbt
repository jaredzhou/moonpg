///|
/// Public API types and traits for moonpg.
///
/// This file re-exports all the core interfaces users need:
/// error types, row iteration, query execution, row mapping,
/// and transaction management.

///|
/// PostgreSQL value type. Re-exported from `@value`.
pub type Value = @value.Value

///|
/// Data format for a PostgreSQL cell or parameter.
/// Re-exported from `@value`.
pub type Format = @value.Format

// ===========================================================================
// PgError
// ===========================================================================

///|
pub(all) suberror PgError {
  ConnectionError(String)
  QueryError(String)
  NoRows
} derive(Debug)

// ===========================================================================
// Value conversion
// ===========================================================================

///|
/// Value conversion error.
pub(all) suberror ValueError {
  ValueError(String)
} derive(Debug)

///|
/// Types that can be converted to a `Value` for use as SQL parameters.
///
/// ```moonbit nocheck
/// impl ToValue for MyType with fn to_value(self) -> Value {
///   ...
/// }
/// ```
pub(open) trait ToValue {
  fn to_value(Self) -> @value.Value
}

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
  fn from_value(@value.Value) -> Self raise ValueError
}

// ===========================================================================
// Rows trait
// ===========================================================================

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

// ===========================================================================
// Row
// ===========================================================================

///|
/// A single row from a query result.
pub struct Row {
  values : Array[Bytes?]
  col_descs : Array[@wire.FieldDescription]
}

///|
/// Read the value at column `col` (zero-based index) as `T`.
pub fn[T : FromValue] Row::get(self : Row, col : Int) -> T raise PgError {
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
        ValueError::ValueError(m) => m
      }
      raise PgError::QueryError("from_value error: \{msg}")
    }
  }
}

///|
/// Read the value of column `name` as `T`.
pub fn[T : FromValue] Row::get_by_name(
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

// ===========================================================================
// ExecResult
// ===========================================================================

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

// ===========================================================================
// QueryExecutor trait
// ===========================================================================

///|
/// Types that can execute SQL queries.
pub(open) trait QueryExecutor {
  async fn query(Self, String, params? : Array[&ToValue]) -> &Rows raise PgError
  async fn query_one(Self, String, params? : Array[&ToValue]) -> Row raise PgError
  async fn execute(Self, String, params? : Array[&ToValue]) -> ExecResult raise PgError
  fn close(Self) -> Unit
}

///|
/// Execute a SELECT query and collect all rows as an array of `T`.
///
/// Rows are automatically drained. Works on any `QueryExecutor`.
///
/// ```moonbit nocheck
/// let users : Array[User] = conn.fetch("SELECT id, name FROM users")
///
/// let names : Array[String] = pool.fetch("SELECT name FROM users")
/// ```
pub async fn[T : FromRow] &QueryExecutor::fetch(
  self : &QueryExecutor,
  sql : String,
  params? : Array[&ToValue],
) -> Array[T] raise PgError {
  let rows = self.query(sql, params?)
  let result : Array[T] = []
  try {
    while rows.has_next() {
      result.push(T::from_row(rows.get_row()))
    }
    rows.close()
    result
  } catch {
    e => {
      rows.close()
      raise e
    }
  }
}

///|
/// Execute a SELECT query and return exactly one row as `T`.
///
/// Raises `NoRows` when the query returns zero rows.
///
/// ```moonbit nocheck
/// let user : User = conn.fetch_one("SELECT id, name FROM users WHERE id = $1", params=[
///   1,
/// ])
/// ```
pub async fn[T : FromRow] &QueryExecutor::fetch_one(
  self : &QueryExecutor,
  sql : String,
  params? : Array[&ToValue],
) -> T raise PgError {
  let rows = self.query(sql, params?)
  try {
    if rows.has_next() {
      let row = rows.get_row()
      rows.close()
      return T::from_row(row)
    }
    rows.close()
    raise NoRows
  } catch {
    e => {
      rows.close()
      raise e
    }
  }
}

// ===========================================================================
// FromRow trait
// ===========================================================================

///|
/// Types that can be constructed from a single database `Row`.
///
/// Implement this trait for custom types to enable use with
/// `fetch` / `fetch_one`.
///
/// ```moonbit nocheck
/// impl FromRow for User with fn from_row(r : Row) -> User raise PgError {
///   User::{ id: r.get(0), name: r.get(1), email: r.get(2) }
/// }
///
/// let users : Array[User] = pool.fetch("SELECT id, name, email FROM users")
/// ```
pub(open) trait FromRow {
  fn from_row(Row) -> Self raise PgError
}

// ===========================================================================
// Tx trait + helpers
// ===========================================================================

///|
/// A database transaction. Extends `QueryExecutor` with commit/rollback.
/// Concrete impl: `DbTx`. Users can impl this trait on mock types for testing.
pub(open) trait Tx: QueryExecutor {
  async fn commit(Self) -> Unit raise PgError
  async fn rollback(Self) -> Unit raise PgError
}

///|
/// Transaction isolation level.
pub(all) enum IsolationLevel {
  ReadCommitted
  RepeatableRead
  Serializable
}

///|
fn IsolationLevel::to_sql(self : IsolationLevel) -> String {
  match self {
    ReadCommitted => "READ COMMITTED"
    RepeatableRead => "REPEATABLE READ"
    Serializable => "SERIALIZABLE"
  }
}

///|
/// Options for `BEGIN` — mirrors PostgreSQL's `BEGIN ...` parameters.
pub(all) struct TxOptions {
  isolation_level : IsolationLevel?
  read_only : Bool?
  deferrable : Bool?
}

///|
pub fn TxOptions::default() -> TxOptions {
  { isolation_level: None, read_only: None, deferrable: None }
}

///|
/// Types that can start a transaction.
pub(open) trait TxBeginner {
  async fn begin_tx(Self, opts? : TxOptions) -> &Tx raise PgError
}

///|
/// Concrete transaction wrapping a Connection.
pub(all) struct DbTx {
  conn : Connection
}

///|
/// Execute a callback inside a transaction.
///
/// 1. Call `beginner.begin_tx()` to start a transaction.
/// 2. Execute `f(tx)`.
/// 3. Success → COMMIT, error → ROLLBACK + re-raise.
///
/// Works with any `TxBeginner`: `Connection`, `Pool`, `PoolConn`.
///
/// # Example
/// ```
/// let new_id = begin_func(conn, fn(tx) {
///   let row = tx.query_one("INSERT INTO users (name) VALUES ($1) RETURNING id", params=["alice"])
///   row.get(0)
/// })
/// ```
pub async fn[T, B : TxBeginner] begin_func(
  beginner : B,
  f : async (&Tx) -> T,
) -> T raise PgError {
  let tx = beginner.begin_tx()
  try {
    let r = f(tx)
    tx.commit()
    r
  } catch {
    e => {
      tx.rollback() catch {
        _ => ()
      }
      raise PgError::ConnectionError(to_repr(e).to_string())
    }
  }
}
