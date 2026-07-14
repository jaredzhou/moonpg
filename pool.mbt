///|
/// Connection pool, inspired by pgxpool.
///
/// ## Concurrency model
///
/// MoonBit's async runtime is single-threaded + cooperative.  The pool
/// uses `@aqueue.Queue(kind=Unbounded)` for idle connections (sync
/// `try_get` / `try_put`) and `get()` (async, blocks) when exhausted.
/// A `Ref[Int]` counter tracks total connections — it is safe because
/// increments happen *before* the first yield point (`connect()`).
///
/// ## Basic usage
///
/// ```
/// let pool = Pool::new(PoolConfig::new("postgres://...", max_conns=10))
///
/// // Option A: implicit acquire — Pool auto-manages lifecycle
/// let rows = pool.query("SELECT 1")
/// while rows.has_next() { let row = rows.get_row() }
/// rows.close()       // PoolRows.close() returns conn to pool
/// let row = pool.query_one("SELECT 42")
/// pool.execute("INSERT ...") |> ignore
/// let tx = pool.begin_tx()
/// tx.commit()        // PoolDbTx.commit() returns conn to pool
///
/// // Option B: explicit acquire — caller manages lifecycle
/// let pc = pool.acquire()
/// defer pc.release()
/// let rows = pc.query("SELECT 1")
/// rows.close()       // PoolRows.close() returns conn to pool
/// let row = pc.query_one("SELECT 42")
/// pc.release()       // caller releases
/// ```

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

pub(all) struct PoolConfig {
  conninfo : String
  max_conns : Int
  min_idle : Int
  max_idle_sec : Int
  max_lifetime_sec : Int
}

pub fn PoolConfig::new(
  conninfo : String,
  max_conns~ : Int = 10,
  min_idle~ : Int = 0,
  max_idle_sec~ : Int = 0,
  max_lifetime_sec~ : Int = 0,
) -> PoolConfig {
  { conninfo, max_conns, min_idle, max_idle_sec, max_lifetime_sec }
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

pub(all) struct IdleConn {
  conn : Connection
  created_at : Int64
  idle_since : Int64
}

// ---------------------------------------------------------------------------
// Pool & PoolConn
// ---------------------------------------------------------------------------

pub(all) struct Pool {
  queue : @aqueue.Queue[IdleConn]
  conninfo : String
  max_conns : Int
  max_idle_sec : Int
  max_lifetime_sec : Int
  count : Ref[Int]
}

pub(all) struct PoolConn {
  conn : Connection
  pool : Pool
  created_at : Int64
  released : Ref[Bool]
}

// ---------------------------------------------------------------------------
// PoolRows — Rows that release back to the pool on close()
// ---------------------------------------------------------------------------

///|
/// Rows from a pooled connection.  Implements `Rows` — identical API
/// to `ConnRows`, but `close()` returns the connection to the pool.
pub(all) struct PoolRows {
  inner : &Rows
  pc : PoolConn
}

///|
pub impl Rows for PoolRows with fn has_next(
  self : PoolRows,
) -> Bool raise PgError {
  self.inner.has_next()
}

///|
pub impl Rows for PoolRows with fn get_row(
  self : PoolRows,
) -> Row raise PgError {
  self.inner.get_row()
}

///|
pub impl Rows for PoolRows with fn columns(
  self : PoolRows,
) -> Array[@wire.FieldDescription] {
  self.inner.columns()
}

///|
/// **Drain the inner reader and return the connection to the pool.**
///
/// Any unread rows are discarded.  The `PoolConn` is released back to
/// the idle queue.  Safe to call multiple times (idempotent release).
pub impl Rows for PoolRows with fn close(self : PoolRows) -> Unit raise PgError {
  self.inner.close()
  self.pc.release()
}

// ---------------------------------------------------------------------------
// Pool constructor
// ---------------------------------------------------------------------------

pub async fn Pool::new(config : PoolConfig) -> Pool raise PgError {
  let pool = Pool::{
    queue: @aqueue.Queue(kind=@aqueue.Unbounded),
    conninfo: config.conninfo,
    max_conns: config.max_conns,
    max_idle_sec: config.max_idle_sec,
    max_lifetime_sec: config.max_lifetime_sec,
    count: Ref(0),
  }
  for _ in 0..<config.min_idle {
    let conn = connect(pool.conninfo)
    let now = @async.now()
    pool.count.val = pool.count.val + 1
    let _ = pool.queue.try_put(IdleConn::{ conn, created_at: now, idle_since: now }) catch {
      _ => {
        conn.close()
        pool.count.val = pool.count.val - 1
        false
      }
    }
  }
  pool
}

pub fn Pool::total(self : Pool) -> Int {
  self.count.val
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

fn Pool::expired(self : Pool, idle : IdleConn) -> Bool {
  if idle.conn.status() != ConnStatus::OK {
    return true
  }
  let now = @async.now()
  if self.max_lifetime_sec > 0 &&
    now - idle.created_at > self.max_lifetime_sec.to_int64() * 1000L {
    return true
  }
  if self.max_idle_sec > 0 &&
    now - idle.idle_since > self.max_idle_sec.to_int64() * 1000L {
    return true
  }
  false
}

// ---------------------------------------------------------------------------
// Acquire
// ---------------------------------------------------------------------------

pub async fn Pool::acquire(self : Pool) -> PoolConn raise PgError {
  let maybe_idle : IdleConn? = self.queue.try_get() catch {
    _ => raise PgError::ConnectionError("pool closed")
  }
  match maybe_idle {
    Some(idle) =>
      if self.expired(idle) {
        idle.conn.close()
        self.count.val = self.count.val - 1
        self.acquire()
      } else {
        PoolConn::{ conn: idle.conn, pool: self, created_at: idle.created_at, released: Ref(false) }
      }
    None =>
      if self.count.val < self.max_conns {
        self.count.val = self.count.val + 1
        let now = @async.now()
        let conn = connect(self.conninfo)
        PoolConn::{ conn, pool: self, created_at: now, released: Ref(false) }
      } else {
        let idle : IdleConn = self.queue.get() catch {
          _ => raise PgError::ConnectionError("pool closed while waiting")
        }
        if idle.conn.status() != ConnStatus::OK || self.expired(idle) {
          idle.conn.close()
          self.count.val = self.count.val - 1
          self.acquire()
        } else {
          PoolConn::{ conn: idle.conn, pool: self, created_at: idle.created_at, released: Ref(false) }
        }
      }
  }
}

// ---------------------------------------------------------------------------
// Release / Close
// ---------------------------------------------------------------------------

pub fn PoolConn::release(self : PoolConn) -> Unit {
  if self.released.val {
    return
  }
  self.released.val = true
  if self.conn.status() != ConnStatus::OK {
    self.conn.close()
    self.pool.count.val = self.pool.count.val - 1
    return
  }
  let idle = IdleConn::{
    conn: self.conn,
    created_at: self.created_at,
    idle_since: @async.now(),
  }
  let ok = self.pool.queue.try_put(idle) catch {
    _ => {
      idle.conn.close()
      self.pool.count.val = self.pool.count.val - 1
      return
    }
  }
  if !ok {
    idle.conn.close()
    self.pool.count.val = self.pool.count.val - 1
  }
}

pub fn PoolConn::close(self : PoolConn) -> Unit {
  self.released.val = true
  self.conn.close()
  self.pool.count.val = self.pool.count.val - 1
}

pub fn Pool::close(self : Pool) -> Unit {
  self.queue.close()
  for ;; {
    let maybe : IdleConn? = self.queue.try_get() catch {
      _ => break
    }
    match maybe {
      Some(idle) => idle.conn.close()
      None => break
    }
  }
}

// ---------------------------------------------------------------------------
// PoolConn: all methods delegate to inner Connection, caller manages release
// ---------------------------------------------------------------------------

pub async fn PoolConn::query(
  self : PoolConn,
  sql : String,
  params? : Array[&ToValue],
) -> &Rows raise PgError {
  self.conn.query(sql, params?)
}

pub async fn PoolConn::query_one(
  self : PoolConn,
  sql : String,
  params? : Array[&ToValue],
) -> Row raise PgError {
  self.conn.query_one(sql, params?)
}

pub async fn PoolConn::execute(
  self : PoolConn,
  sql : String,
  params? : Array[&ToValue],
) -> ExecResult raise PgError {
  self.conn.execute(sql, params?)
}

// ---------------------------------------------------------------------------
// PoolDbTx — Tx that releases back to the pool on commit/rollback
// ---------------------------------------------------------------------------

///|
/// Transaction from a pooled connection.  Proxies `DbTx` for queries
/// and releases the connection on `commit()` / `rollback()`.
pub(all) struct PoolDbTx {
  inner : DbTx
  pc : PoolConn
}

///|
pub impl QueryExecutor for PoolDbTx with fn query(
  self : PoolDbTx,
  sql : String,
  params? : Array[&ToValue],
) -> &Rows raise PgError {
  self.inner.query(sql, params?)
}

///|
pub impl QueryExecutor for PoolDbTx with fn query_one(
  self : PoolDbTx,
  sql : String,
  params? : Array[&ToValue],
) -> Row raise PgError {
  self.inner.query_one(sql, params?)
}

///|
pub impl QueryExecutor for PoolDbTx with fn execute(
  self : PoolDbTx,
  sql : String,
  params? : Array[&ToValue],
) -> ExecResult raise PgError {
  self.inner.execute(sql, params?)
}

///|
pub impl Tx for PoolDbTx with fn commit(self : PoolDbTx) -> Unit raise PgError {
  self.inner.commit()
  self.pc.release()
}

///|
pub impl Tx for PoolDbTx with fn rollback(self : PoolDbTx) -> Unit raise PgError {
  self.inner.rollback()
  self.pc.release()
}

// ---------------------------------------------------------------------------
// PoolConn::begin_tx
// ---------------------------------------------------------------------------

///|
/// Begin a transaction on this pooled connection.
/// Caller must call `pc.release()` after `tx.commit()` / `tx.rollback()`.
pub async fn PoolConn::begin_tx(self : PoolConn) -> DbTx raise PgError {
  self.conn.execute("BEGIN") |> ignore
  DbTx::{ conn: self.conn, pool: None }
}

// ---------------------------------------------------------------------------
// Pool::begin_tx
// ---------------------------------------------------------------------------

///|
/// Acquire a connection from the pool and begin a transaction.
/// Connection is returned to the pool on `commit()` or `rollback()`.
pub async fn Pool::begin_tx(self : Pool) -> PoolDbTx raise PgError {
  let pc = self.acquire()
  let tx = pc.begin_tx() catch {
    e => {
      pc.close()
      raise e
    }
  }
  PoolDbTx::{ inner: tx, pc }
}

// ---------------------------------------------------------------------------
// Pool: QueryExecutor — acquire, delegate, release on error
// ---------------------------------------------------------------------------

pub impl QueryExecutor for Pool with fn query(
  self : Pool,
  sql : String,
  params? : Array[&ToValue],
) -> &Rows raise PgError {
  let pc = self.acquire()
  let rows = pc.query(sql, params?) catch {
    e => {
      pc.close()
      raise e
    }
  }
  PoolRows::{ inner: rows, pc }
}

pub impl QueryExecutor for Pool with fn query_one(
  self : Pool,
  sql : String,
  params? : Array[&ToValue],
) -> Row raise PgError {
  let pc = self.acquire()
  let row = pc.query_one(sql, params?) catch {
    e => {
      pc.close()
      raise e
    }
  }
  pc.release()
  row
}

pub impl QueryExecutor for Pool with fn execute(
  self : Pool,
  sql : String,
  params? : Array[&ToValue],
) -> ExecResult raise PgError {
  let pc = self.acquire()
  let result = pc.execute(sql, params?) catch {
    e => {
      pc.close()
      raise e
    }
  }
  pc.release()
  result
}

