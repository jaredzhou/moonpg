///|
/// A database transaction. Extends `QueryExecutor` with commit/rollback.
/// Concrete impl: `DbTx`. Users can impl this trait on mock types for testing.
pub(open) trait Tx: QueryExecutor {
  async fn commit(Self) -> Unit raise PgError
  async fn rollback(Self) -> Unit raise PgError
}

///|
/// Types that can start a transaction.
pub(open) trait TxBeginner {
  async fn begin_tx(Self) -> DbTx raise PgError
}

///|
/// Concrete transaction wrapping a Connection and optional pool
/// (for returning the connection on commit/rollback).
pub(all) struct DbTx {
  conn : Connection
  pool : Pool?
}

///|
pub impl TxBeginner for Connection with fn begin_tx(self : Connection) -> DbTx raise PgError {
  Connection::execute(self, "BEGIN") |> ignore
  DbTx::{ conn: self, pool: None }
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
/// 1. Call f(tx)
/// 2. success → COMMIT, error → ROLLBACK + re-raise
///
/// For a pooled transaction (`PoolDbTx`), `commit()` / `rollback()`
/// also returns the connection to the pool.
///
/// # Example
/// ```
/// let new_id = begin_func(pool.begin_tx(), fn(tx) {
///   let row = tx.query_one("INSERT INTO users (name) VALUES ($1) RETURNING id", params=["alice"])
///   row.get[Int](0)
/// })
/// ```
pub async fn[T, TX : Tx] begin_func(
  tx : TX,
  f : async (TX) -> T,
) -> T raise PgError {
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
