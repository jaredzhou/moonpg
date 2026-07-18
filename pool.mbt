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
  health_check : Bool
  maintenance_interval_sec : Int
}

///|
pub fn PoolConfig::new(
  conninfo : String,
  max_conns? : Int = 10,
  min_idle? : Int = 0,
  max_idle_sec? : Int = 0,
  max_lifetime_sec? : Int = 0,
  health_check? : Bool = false,
  maintenance_interval_sec? : Int = 0,
) -> PoolConfig {
  {
    conninfo,
    max_conns,
    min_idle,
    max_idle_sec,
    max_lifetime_sec,
    health_check,
    maintenance_interval_sec,
  }
}

// ---------------------------------------------------------------------------
// PoolStats
// ---------------------------------------------------------------------------

///|
/// Snapshot of pool statistics.
pub(all) struct PoolStats {
  /// Total connections (idle + active).
  total_connections : Int
  /// Connections sitting idle in the pool.
  idle_connections : Int
  /// Connections currently checked out.
  active_connections : Int
  /// Total number of `acquire()` calls.
  acquire_count : Int64
  /// Number of acquires that had to wait because the pool was exhausted.
  acquire_wait_count : Int64
  /// Cumulative milliseconds spent waiting in `acquire()`.
  acquire_wait_duration_ms : Int64
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

///|
pub(all) struct IdleConn {
  conn : Connection
  created_at : Int64
  idle_since : Int64
}

// ---------------------------------------------------------------------------
// Pool & PoolConn
// ---------------------------------------------------------------------------

///|
pub(all) struct Pool {
  queue : @aqueue.Queue[IdleConn]
  conninfo : String
  max_conns : Int
  min_idle : Int
  max_idle_sec : Int
  max_lifetime_sec : Int
  health_check : Bool
  maintenance_interval_sec : Int
  count : Ref[Int]
  idle_count : Ref[Int]
  running : Ref[Bool]
  acquire_count : Ref[Int64]
  acquire_wait_count : Ref[Int64]
  acquire_wait_duration : Ref[Int64]
}

///|
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
pub impl Rows for PoolRows with fn has_next(self : PoolRows) -> Bool raise PgError {
  self.inner.has_next()
}

///|
pub impl Rows for PoolRows with fn get_row(self : PoolRows) -> Row raise PgError {
  self.inner.get_row()
}

///|
pub impl Rows for PoolRows with fn columns(self : PoolRows) -> Array[
  @wire.FieldDescription,
] {
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

///|
pub async fn Pool::new(config : PoolConfig) -> Pool raise PgError {
  let pool = Pool::{
    queue: @aqueue.Queue(kind=@aqueue.Unbounded),
    conninfo: config.conninfo,
    max_conns: config.max_conns,
    min_idle: config.min_idle,
    max_idle_sec: config.max_idle_sec,
    max_lifetime_sec: config.max_lifetime_sec,
    health_check: config.health_check,
    maintenance_interval_sec: config.maintenance_interval_sec,
    count: Ref(0),
    idle_count: Ref(0),
    running: Ref(false),
    acquire_count: Ref(0L),
    acquire_wait_count: Ref(0L),
    acquire_wait_duration: Ref(0L),
  }
  // Pre-fill idle connections up to min_idle
  for _ in 0..<config.min_idle {
    let conn = connect(pool.conninfo)
    let now = @async.now()
    pool.count.val = pool.count.val + 1
    let ok = pool.queue.try_put(IdleConn::{
      conn,
      created_at: now,
      idle_since: now,
    }) catch {
      _ => {
        conn.close()
        pool.count.val = pool.count.val - 1
        false
      }
    }
    if ok {
      pool.idle_count.val = pool.idle_count.val + 1
    }
  }
  pool
}

///|
pub fn Pool::total(self : Pool) -> Int {
  self.count.val
}

///|
/// Number of idle connections currently in the pool.
pub fn Pool::idle(self : Pool) -> Int {
  self.idle_count.val
}

///|
/// Return a snapshot of pool statistics.
pub fn Pool::stats(self : Pool) -> PoolStats {
  PoolStats::{
    total_connections: self.count.val,
    idle_connections: self.idle_count.val,
    active_connections: self.count.val - self.idle_count.val,
    acquire_count: self.acquire_count.val,
    acquire_wait_count: self.acquire_wait_count.val,
    acquire_wait_duration_ms: self.acquire_wait_duration.val,
  }
}

// ---------------------------------------------------------------------------
// Background maintenance
// ---------------------------------------------------------------------------

///|
/// Start background maintenance.
///
/// Periodically cleans expired idle connections and refills up to `min_idle`.
/// Runs until `Pool::close()` is called.  Call this once after creating the
/// pool.
///
/// When `maintenance_interval_sec` is 0 (the default) this is a no-op —
/// maintenance happens lazily during `acquire()` / `release()` instead.
pub async fn Pool::start_maintenance(self : Pool) -> Unit {
  if self.maintenance_interval_sec <= 0 {
    return
  }
  self.running.val = true
  @async.with_task_group() <| group => {
    group.spawn_loop(no_wait=true) <| () => {
      @async.sleep(self.maintenance_interval_sec * 1000)
      if !self.running.val {
        raise @async.BreakFromSpawnLoop
      }
      self.maintain()
    }
  }
}

///|
/// Run one round of maintenance:
///
/// 1. Drain all idle connections from the queue, closing expired ones.
/// 2. Put the good ones back.
/// 3. Create new connections if idle count is below `min_idle`.
///
/// Called automatically by the background maintenance loop; may also be
/// called manually.
pub async fn Pool::maintain(self : Pool) -> Unit {
  // --- drain & filter -------------------------------------------------------
  let good : Array[IdleConn] = []
  for ;; {
    let maybe : IdleConn? = self.queue.try_get() catch { _ => break }
    match maybe {
      None => break
      Some(idle) => {
        self.idle_count.val = self.idle_count.val - 1
        if self.expired(idle) {
          idle.conn.close()
          self.count.val = self.count.val - 1
        } else {
          good.push(idle)
        }
      }
    }
  }
  // --- put good ones back ---------------------------------------------------
  for idle in good {
    let ok = self.queue.try_put(idle) catch {
      _ => {
        idle.conn.close()
        self.count.val = self.count.val - 1
        false
      }
    }
    if ok {
      self.idle_count.val = self.idle_count.val + 1
    } else {
      idle.conn.close()
      self.count.val = self.count.val - 1
    }
  }
  // --- refill to min_idle ---------------------------------------------------
  if self.min_idle > 0 {
    for _ in 0..<(self.min_idle - self.idle_count.val) {
      if self.count.val >= self.max_conns {
        break
      }
      let conn = connect(self.conninfo) catch {
        _ => break // stop refilling on error
      }
      self.count.val = self.count.val + 1
      let now = @async.now()
      let ok = self.queue.try_put(IdleConn::{
        conn,
        created_at: now,
        idle_since: now,
      }) catch {
        _ => {
          conn.close()
          self.count.val = self.count.val - 1
          break
        }
      }
      if ok {
        self.idle_count.val = self.idle_count.val + 1
      } else {
        conn.close()
        self.count.val = self.count.val - 1
        break
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

///|
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

///|
pub async fn Pool::acquire(self : Pool) -> PoolConn raise PgError {
  self.acquire_count.val = self.acquire_count.val + 1L
  let maybe_idle : IdleConn? = self.queue.try_get() catch {
    _ => raise PgError::ConnectionError("pool closed")
  }
  match maybe_idle {
    Some(idle) => {
      self.idle_count.val = self.idle_count.val - 1
      if self.expired(idle) {
        idle.conn.close()
        self.count.val = self.count.val - 1
        self.acquire()
      } else {
        self.checkout(idle)
      }
    }
    None =>
      if self.count.val < self.max_conns {
        self.count.val = self.count.val + 1
        let now = @async.now()
        let conn = connect(self.conninfo)
        PoolConn::{ conn, pool: self, created_at: now, released: Ref(false) }
      } else {
        let wait_start = @async.now()
        self.acquire_wait_count.val = self.acquire_wait_count.val + 1L
        let idle : IdleConn = self.queue.get() catch {
          _ => raise PgError::ConnectionError("pool closed while waiting")
        }
        self.acquire_wait_duration.val = self.acquire_wait_duration.val +
          @async.now() -
          wait_start
        self.idle_count.val = self.idle_count.val - 1
        if idle.conn.status() != ConnStatus::OK || self.expired(idle) {
          idle.conn.close()
          self.count.val = self.count.val - 1
          self.acquire()
        } else {
          self.checkout(idle)
        }
      }
  }
}

///|
/// Validate and optionally health-check an idle connection before checkout.
async fn Pool::checkout(self : Pool, idle : IdleConn) -> PoolConn raise PgError {
  if self.health_check {
    try idle.conn.execute("SELECT 1") |> ignore catch {
      _ => {
        idle.conn.close()
        self.count.val = self.count.val - 1
        return self.acquire()
      }
    }
  }
  PoolConn::{
    conn: idle.conn,
    pool: self,
    created_at: idle.created_at,
    released: Ref(false),
  }
}

// ---------------------------------------------------------------------------
// Release / Close
// ---------------------------------------------------------------------------

///|
pub fn PoolConn::release(self : PoolConn) -> Unit {
  if self.released.val {
    return
  }
  self.released.val = true
  // Drop connection if it has exceeded its lifetime or is in a bad state.
  let now = @async.now()
  if self.conn.status() != ConnStatus::OK {
    self.conn.close()
    self.pool.count.val = self.pool.count.val - 1
    return
  }
  if self.pool.max_lifetime_sec > 0 &&
    now - self.created_at > self.pool.max_lifetime_sec.to_int64() * 1000L {
    self.conn.close()
    self.pool.count.val = self.pool.count.val - 1
    return
  }
  let idle = IdleConn::{
    conn: self.conn,
    created_at: self.created_at,
    idle_since: now,
  }
  let ok = self.pool.queue.try_put(idle) catch {
    _ => {
      idle.conn.close()
      self.pool.count.val = self.pool.count.val - 1
      return
    }
  }
  if ok {
    self.pool.idle_count.val = self.pool.idle_count.val + 1
  } else {
    idle.conn.close()
    self.pool.count.val = self.pool.count.val - 1
  }
}

///|
pub fn PoolConn::close(self : PoolConn) -> Unit {
  self.released.val = true
  self.conn.close()
  self.pool.count.val = self.pool.count.val - 1
}

///|
pub fn Pool::close(self : Pool) -> Unit {
  self.running.val = false
  self.queue.close()
  for ;; {
    let maybe : IdleConn? = self.queue.try_get() catch { _ => break }
    match maybe {
      Some(idle) => {
        idle.conn.close()
        self.idle_count.val = self.idle_count.val - 1
      }
      None => break
    }
  }
}

// ---------------------------------------------------------------------------
// PoolConn: all methods delegate to inner Connection, caller manages release
// ---------------------------------------------------------------------------

///|
pub async fn PoolConn::query(
  self : PoolConn,
  sql : String,
  params? : Array[&ToValue],
) -> &Rows raise PgError {
  self.conn.query(sql, params?)
}

///|
pub async fn PoolConn::query_one(
  self : PoolConn,
  sql : String,
  params? : Array[&ToValue],
) -> Row raise PgError {
  self.conn.query_one(sql, params?)
}

///|
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
// PoolConn::begin_tx (TxBeginner)
// ---------------------------------------------------------------------------

///|
/// Begin a transaction on this pooled connection.
/// Caller must call `pc.release()` after `tx.commit()` / `tx.rollback()`.
pub impl TxBeginner for PoolConn with fn begin_tx(
  self : PoolConn,
  opts? : TxOptions,
) -> &Tx raise PgError {
  self.conn.execute(
    build_begin_sql(
      match opts {
        Some(o) => o
        None => TxOptions::default()
      },
    ),
  )
  |> ignore
  DbTx::{ conn: self.conn }
}

// ---------------------------------------------------------------------------
// Pool::begin_tx (TxBeginner)
// ---------------------------------------------------------------------------

///|
/// Acquire a connection from the pool and begin a transaction.
/// Connection is returned to the pool on `commit()` or `rollback()`.
pub impl TxBeginner for Pool with fn begin_tx(self : Pool, opts? : TxOptions) -> &Tx raise PgError {
  let pc = self.acquire()
  let sql = build_begin_sql(
    match opts {
      Some(o) => o
      None => TxOptions::default()
    },
  )
  try pc.conn.execute(sql) |> ignore catch {
    e => {
      pc.close()
      raise e
    }
  }
  let inner = DbTx::{ conn: pc.conn }
  PoolDbTx::{ inner, pc }
}

// ---------------------------------------------------------------------------
// Pool: QueryExecutor — acquire, delegate, release on error
// ---------------------------------------------------------------------------

///|
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

///|
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

///|
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
