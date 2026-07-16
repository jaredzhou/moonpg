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
  {
    isolation_level: None,
    read_only: None,
    deferrable: None,
  }
}

///|
/// Build a `BEGIN` SQL string from options.
pub fn build_begin_sql(opts : TxOptions) -> String {
  let parts : Array[String] = []
  match opts.isolation_level {
    Some(level) => parts.push("ISOLATION LEVEL \{level.to_sql()}")
    None => ()
  }
  match opts.read_only {
    Some(true) => parts.push("READ ONLY")
    Some(false) => parts.push("READ WRITE")
    None => ()
  }
  match opts.deferrable {
    Some(true) => parts.push("DEFERRABLE")
    Some(false) => parts.push("NOT DEFERRABLE")
    None => ()
  }
  if parts.is_empty() {
    "BEGIN"
  } else {
    "BEGIN \{parts.join(" ")}"
  }
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
pub impl TxBeginner for Connection with fn begin_tx(
  self : Connection,
  opts? : TxOptions,
) -> &Tx raise PgError {
  Connection::execute(self, build_begin_sql(match opts {
    Some(o) => o
    None => TxOptions::default()
  })) |> ignore
  DbTx::{ conn: self }
}

///|
pub impl QueryExecutor for DbTx with fn query(
  self : DbTx,
  sql : String,
  params? : Array[&ToValue],
) -> &Rows raise PgError {
  Connection::query(self.conn, sql, params?)
}

///|
pub impl QueryExecutor for DbTx with fn query_one(
  self : DbTx,
  sql : String,
  params? : Array[&ToValue],
) -> Row raise PgError {
  Connection::query_one(self.conn, sql, params?)
}

///|
pub impl QueryExecutor for DbTx with fn execute(
  self : DbTx,
  sql : String,
  params? : Array[&ToValue],
) -> ExecResult raise PgError {
  Connection::execute(self.conn, sql, params?)
}

///|
pub impl Tx for DbTx with fn commit(self : DbTx) -> Unit raise PgError {
  Connection::execute(self.conn, "COMMIT") |> ignore
}

///|
pub impl Tx for DbTx with fn rollback(self : DbTx) -> Unit raise PgError {
  Connection::execute(self.conn, "ROLLBACK") |> ignore
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
