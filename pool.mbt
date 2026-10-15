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
/// defer rows.close()   // PoolRows.close() returns conn to pool
/// while rows.has_next() { let row = rows.get_row() }
/// let row = pool.query_one("SELECT 42")
/// pool.execute("INSERT ...") |> ignore
/// let tx = pool.begin_tx()
/// tx.commit()        // PoolDbTx.commit() returns conn to pool
///
/// // Option B: explicit acquire — caller manages lifecycle
/// let pc = pool.acquire()
/// defer pc.release()
/// let rows = pc.query("SELECT 1")
/// defer rows.close()   // PoolRows.close() returns conn to pool
/// let row = pc.query_one("SELECT 42")
/// pc.release()       // caller releases
/// ```
///
/// ## Expiry
///
/// Stale connections are dropped when the pool is used — there is no
/// background task, so an unused pool never touches its connections:
///
/// - `acquire()` discards a dequeued idle connection that is dead, or that has
///   been idle past `max_idle_sec` while the pool holds more than `min_idle`
///   connections, and opens a fresh connection instead.
/// - `release()` discards a connection whose socket is no longer usable.
///
/// `max_idle_sec` never trims the warm `min_idle` connections, so the pool does
/// not drop a live connection only to reconnect on the next request.  Nothing
/// refills the pool: `min_idle` is pre-warmed once at `Pool::new`.

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

pub(all) struct PoolConfig {
  conninfo : String
  max_conns : Int32
  min_idle : Int32
  max_idle_sec : Int32
  health_check : Bool
}

///|
pub fn PoolConfig::new(
  conninfo : String,
  max_conns~ : Int32 = 10,
  min_idle~ : Int32 = 0,
  max_idle_sec~ : Int32 = 0,
  health_check~ : Bool = false,
) -> PoolConfig {
  { conninfo, max_conns, min_idle, max_idle_sec, health_check, }
}

// ---------------------------------------------------------------------------
// PoolStats
// ---------------------------------------------------------------------------

///|
/// Snapshot of pool statistics.
pub(all) struct PoolStats {
  /// Total connections (idle + active).
  total_connections : Int32
  /// Connections sitting idle in the pool.
  idle_connections : Int32
  /// Connections currently checked out.
  active_connections : Int32
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
  idle_since : Int64
}

// ---------------------------------------------------------------------------
// Pool & PoolConn
// ---------------------------------------------------------------------------

///|
pub(all) struct Pool {
  queue : @aqueue.Queue[IdleConn]
  conninfo : String
  max_conns : Int32
  min_idle : Int32
  max_idle_sec : Int32
  health_check : Bool
  count : Ref[Int32]
  idle_count : Ref[Int32]
  closed : Ref[Bool]
  acquire_count : Ref[Int64]
  acquire_wait_count : Ref[Int64]
  acquire_wait_duration : Ref[Int64]
}

///|
pub extend Pool with Closer::{close}

///|
pub extend Pool with QueryExecutor::{execute, query, query_one}

///|
pub extend Pool with Fetching::{fetch, fetch_one}

///|
pub extend Pool with TxBeginner::{begin_tx}

///|
pub(all) struct PoolConn {
  conn : Connection
  pool : Pool
  released : Ref[Bool]
}

///|
pub extend PoolConn with Closer::{close}

///|
pub extend PoolConn with TxBeginner::{begin_tx}

///|
pub extend PoolConn with Fetching::{fetch, fetch_one}

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
pub extend PoolRows with Rows::{has_next, close, get_row, columns}

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
    health_check: config.health_check,
    count: Ref(0),
    idle_count: Ref(0),
    closed: Ref(false),
    acquire_count: Ref(0L),
    acquire_wait_count: Ref(0L),
    acquire_wait_duration: Ref(0L),
  }
  // Pre-fill idle connections up to min_idle
  for _ in 0..<config.min_idle {
    let conn = connect(pool.conninfo)
    let now = @async.now()
    pool.count.val = pool.count.val + 1
    let ok = pool.queue.try_put(IdleConn::{ conn, idle_since: now, }) catch {
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
pub fn Pool::total(self : Pool) -> Int32 {
  self.count.val
}

///|
/// Number of idle connections currently in the pool.
pub fn Pool::idle(self : Pool) -> Int32 {
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
// Validation
// ---------------------------------------------------------------------------

///|
/// Decide whether an idle connection that was just taken off the idle queue
/// should be discarded instead of handed out.
///
/// `surplus` must be `true` when the pool would still have at least `min_idle`
/// idle connections left after dropping this one.
fn Pool::expired(self : Pool, idle : IdleConn, surplus~ : Bool) -> Bool {
  if idle.conn.status() != ConnStatus::OK {
    return true
  }
  let now = @async.now()
  // Idle time only trims the surplus.  The warm `min_idle` connections survive,
  // so a live connection is never dropped just to be reconnected on the next
  // acquire.
  if self.max_idle_sec > 0 &&
    surplus &&
    now - idle.idle_since > self.max_idle_sec.to_int64() * 1000L {
    return true
  }
  false
}

// ---------------------------------------------------------------------------
// Maintenance — ping the idle connections
// ---------------------------------------------------------------------------

///|
/// Ping every idle connection and drop the ones that are gone.
///
/// A `SELECT 1` is the only way to learn that the server dropped a connection
/// behind our back: a clean close is not visible until the next I/O, and a
/// black-holed connection only until `read_timeout` expires.  Pinging before a
/// connection is handed out means callers never meet a dead one.
///
/// Dead connections are reconnected only while the pool is below `min_idle`
/// (bounded by `max_conns`), so the warm set survives while surplus that died
/// simply shrinks the pool.
///
/// This drains the idle queue while it runs, so a concurrent `acquire()` may
/// open a fresh connection instead of reusing an idle one.  A ping on a
/// black-holed connection costs up to `read_timeout` per connection.
pub async fn Pool::ping_idle(self : Pool) -> Unit {
  let good : Array[IdleConn] = []
  let mut dead = 0
  // --- drain, ping, filter --------------------------------------------------
  for ;; {
    let maybe : IdleConn? = self.queue.try_get() catch { _ => break }
    match maybe {
      None => break
      Some(idle) => {
        self.idle_count.val = self.idle_count.val - 1
        let alive = try {
          idle.conn.execute("SELECT 1") |> ignore
          true
        } catch {
          _ => false
        }
        if alive {
          good.push(idle)
        } else {
          idle.conn.close()
          self.count.val = self.count.val - 1
          dead = dead + 1
        }
      }
    }
  }
  // --- put the survivors back -----------------------------------------------
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
  // --- reconnect what died, up to the warm `min_idle` set --------------------
  for _ in 0..<dead {
    if self.closed.val ||
      self.idle_count.val >= self.min_idle ||
      self.count.val >= self.max_conns {
      break
    }
    let conn = connect(self.conninfo) catch { _ => break }
    self.count.val = self.count.val + 1
    let now = @async.now()
    let ok = self.queue.try_put(IdleConn::{ conn, idle_since: now, }) catch {
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

///|
/// Ping the idle connections every `interval_sec` seconds, in the background.
///
/// This is the periodic version of `ping_idle`: a connection the server dropped
/// while it sat idle is then found and replaced *before* a caller asks for one,
/// so callers do not meet dead connections at all.
///
/// The loop is a child task of `group`, because the runtime has no detached
/// tasks: it lives exactly as long as `group` does, and stops early once
/// `Pool::close()` is called (within ~500ms).  Call it once per pool — every
/// call starts another loop.
///
/// `interval_sec <= 0` disables the loop.
pub fn[X] Pool::start_maintenance(
  self : Pool,
  group~ : @async.TaskGroup[X],
  interval_sec~ : Int32 = 30,
) -> Unit {
  if interval_sec <= 0 {
    return
  }
  let interval_ms = interval_sec.to_int64() * 1000L
  // Sleep in slices so that `Pool::close()` stops the loop promptly.
  let slice_ms = 500
  group.spawn_bg(no_wait=true, allow_failure=true) <| () => {
    let mut last = @async.now()
    while !self.closed.val {
      @async.sleep(slice_ms)
      if self.closed.val {
        break
      }
      let now = @async.now()
      if now - last >= interval_ms {
        last = now
        self.ping_idle()
      }
    }
  }
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
      let surplus = self.idle_count.val >= self.min_idle
      if self.expired(idle, surplus~) {
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
        errdefer {
          // Release the slot reserved above: no connection was created.
          self.count.val = self.count.val - 1
        }
        let conn = connect(self.conninfo)
        PoolConn::{ conn, pool: self, released: Ref(false), }
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
        let surplus = self.idle_count.val >= self.min_idle
        if self.expired(idle, surplus~) {
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
  PoolConn::{ conn: idle.conn, pool: self, released: Ref(false), }
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
  // Drop the connection if it is in a bad state.
  if self.conn.status() != ConnStatus::OK {
    self.conn.close()
    self.pool.count.val = self.pool.count.val - 1
    return
  }
  let idle = IdleConn::{ conn: self.conn, idle_since: @async.now(), }
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
/// Destroy this pooled connection (does NOT return it to the pool).
/// Prefer `release()` to recycle the connection.
pub impl Closer for PoolConn with fn close(self : PoolConn) -> Unit {
  self.released.val = true
  self.conn.close()
  self.pool.count.val = self.pool.count.val - 1
}

///|
/// Close the pool and all idle connections.
pub impl Closer for Pool with fn close(self : Pool) -> Unit {
  self.closed.val = true
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
// PoolConn: QueryExecutor impl
// ---------------------------------------------------------------------------

///|
pub impl QueryExecutor for PoolConn with fn query(
  self : PoolConn,
  sql : String,
  params? : Array[&ToValue],
) -> &Rows raise PgError {
  self.conn.query(sql, params?)
}

///|
pub impl QueryExecutor for PoolConn with fn query_one(
  self : PoolConn,
  sql : String,
  params? : Array[&ToValue],
) -> Row raise PgError {
  self.conn.query_one(sql, params?)
}

///|
pub impl QueryExecutor for PoolConn with fn execute(
  self : PoolConn,
  sql : String,
  params? : Array[&ToValue],
) -> ExecResult raise PgError {
  self.conn.execute(sql, params?)
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

///|
pub impl Fetching for PoolConn

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
pub extend PoolDbTx with QueryExecutor::{execute, query, query_one}

///|
pub extend PoolDbTx with Tx::{commit, rollback}

///|
pub extend PoolDbTx with Fetching::{fetch, fetch_one}

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
pub impl Fetching for PoolDbTx

///|

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
  DbTx::{ conn: self.conn, }
}

// ---------------------------------------------------------------------------
// Pool::begin_tx (TxBeginner)
// ---------------------------------------------------------------------------

///|
/// Acquire a connection from the pool and begin a transaction.
/// Connection is returned to the pool on `commit()` or `rollback()`.
pub impl TxBeginner for Pool with fn begin_tx(self : Pool, opts? : TxOptions) -> &Tx raise PgError {
  let pc = self.acquire()
  errdefer pc.close()
  let sql = build_begin_sql(
    match opts {
      Some(o) => o
      None => TxOptions::default()
    },
  )
  pc.conn.execute(sql) |> ignore
  let inner = DbTx::{ conn: pc.conn, }
  PoolDbTx::{ inner, pc, }
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
  errdefer pc.close()
  let rows = pc.query(sql, params?)
  PoolRows::{ inner: rows, pc, }
}

///|
pub impl QueryExecutor for Pool with fn query_one(
  self : Pool,
  sql : String,
  params? : Array[&ToValue],
) -> Row raise PgError {
  let pc = self.acquire()
  errdefer pc.close()
  let row = pc.query_one(sql, params?)
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
  errdefer pc.close()
  let result = pc.execute(sql, params?)
  pc.release()
  result
}

///|
pub impl Fetching for Pool
