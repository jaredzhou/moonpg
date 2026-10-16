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
/// A stale connection is noticed in one of three places:
///
/// - **On checkout.**  `acquire()` inspects the connection it just took off the
///   idle queue, before handing it out: a socket already known to be bad, a
///   connection past `max_lifetime_sec`, or one parked past `max_idle_sec` while
///   dropping it would still leave `min_conn` connections is discarded on the
///   spot, and `acquire()` moves on to the next parked connection.  It opens a new
///   connection only when the idle queue is empty (and waits for a release when
///   the pool is already at `max_conns`).  Then, if the connection it settled on
///   has been parked longer than `CHECKOUT_PING_IDLE_MS` (2s), it is pinged — the
///   server can drop a connection behind our back, and only a round trip shows it.
///   A failed ping discards that one too and `acquire()` carries on the same way:
///   the caller gets a live connection, or the `PgError` that the connect itself
///   raised.
/// - **On release.**  A connection whose socket is no longer usable, or that is
///   past `max_lifetime_sec`, is destroyed instead of parked, so the checkout
///   above never sees it.
/// - **In a maintenance round.**  `Pool::maintain()` pings every parked
///   connection, drops the dead ones, closes the idle surplus past `max_idle_sec`
///   and rotates the over-age ones — everything the checkout would otherwise have
///   to do, done in the background.  `Pool::start_maintenance` runs one such
///   round every `interval_sec`.
///
/// `max_idle_sec` never trims the pool below `min_conn` connections, so the pool
/// does not drop a live connection only to reconnect on the next request;
/// `max_lifetime_sec` does trim below it, which is why a maintenance round reopens
/// what it rotates.  A ping is a health check, not a use: it does not reset the
/// idle timer, so a connection the loop pinged still ages out towards
/// `max_idle_sec`.  Without the loop, `min_conn` is only pre-warmed at `Pool::new`.

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

pub(all) struct PoolConfig {
  conninfo : String
  /// Ceiling on connections, checked out or idle.  `acquire()` waits for a
  /// release once this many are out.
  max_conns : Int32
  /// Minimum number of connections: pre-warmed at `Pool::new`, and the floor
  /// `max_idle_sec` does not trim below.  Counted in connections, not idle ones —
  /// a connection a caller is holding already satisfies it.  `0` keeps only what
  /// a request asks for.
  min_conn : Int32
  /// Idle timeout in seconds: a connection parked this long is dropped — by the
  /// `acquire()` that takes it off the queue, or by a maintenance round — while
  /// the pool would still hold `min_conn` connections.  `0` disables it.
  max_idle_sec : Int32
  /// Hard cap on how old a connection may get, in seconds.  An over-age
  /// connection is never handed out and is not parked on release; maintenance
  /// replaces it.  `0` disables the cap.
  max_lifetime_sec : Int32
}

///|
pub fn PoolConfig::new(
  conninfo : String,
  max_conns~ : Int32 = 10,
  min_conn~ : Int32 = 0,
  max_idle_sec~ : Int32 = 0,
  max_lifetime_sec~ : Int32 = 0,
) -> PoolConfig {
  { conninfo, max_conns, min_conn, max_idle_sec, max_lifetime_sec, }
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
  max_conns : Int32
  min_conn : Int32
  max_idle_sec : Int32
  max_lifetime_sec : Int32
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
  created_at : Int64
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
/// Create a pool.
///
/// Nothing runs in the background.  What the pool knows about a connection it is
/// about to hand out, it checks right there in `acquire()`: the timestamps
/// (`max_lifetime_sec`, and `max_idle_sec` while dropping it would still leave
/// `min_conn` connections), and a ping when the connection has been parked longer
/// than `CHECKOUT_PING_IDLE_MS` — 2 seconds — because a connection the server
/// dropped behind our back is invisible to `Connection::status` until something
/// talks to it.  A connection that fails any of those is discarded and
/// `acquire()` moves on to another one, so the request pays a round trip or a
/// connect rather than failing; a connection released less than 2 seconds ago is
/// handed out without a ping.
///
/// `Pool::start_maintenance` does the same work in the background instead, so the
/// pings happen before a request asks for a connection rather than during one.  It
/// is a separate call because the runtime has no detached tasks — the loop has to
/// be a child task of a group the caller owns — and because the pool is complete
/// without it.  See the module doc for the full expiry rules.
pub async fn Pool::new(config : PoolConfig) -> Pool raise PgError {
  let pool = Pool::{
    queue: @aqueue.Queue(kind=@aqueue.Unbounded),
    conninfo: config.conninfo,
    max_conns: config.max_conns,
    min_conn: config.min_conn,
    max_idle_sec: config.max_idle_sec,
    max_lifetime_sec: config.max_lifetime_sec,
    count: Ref(0),
    idle_count: Ref(0),
    closed: Ref(false),
    acquire_count: Ref(0L),
    acquire_wait_count: Ref(0L),
    acquire_wait_duration: Ref(0L),
  }
  // Pre-fill idle connections up to min_conn
  for _ in 0..<config.min_conn {
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
/// `surplus` must be `true` when the pool would still have at least `min_conn`
/// connections left after dropping this one — idle or checked out, `min_conn`
/// counts connections, not idle ones.
fn Pool::expired(self : Pool, idle : IdleConn, surplus~ : Bool) -> Bool {
  if idle.conn.status() != ConnStatus::OK {
    return true
  }
  let now = @async.now()
  // Age is a hard cap: an over-lifetime connection is rotated even if it is one
  // of the `min_conn` connections, because the server side may have stopped
  // using it.  Maintenance reopens what this costs.
  if self.max_lifetime_sec > 0 &&
    now - idle.created_at > self.max_lifetime_sec.to_int64() * 1000L {
    return true
  }
  // Idle time only trims the surplus.  The `min_conn` connections survive, so a
  // live connection is not dropped just to be reconnected on the next acquire.
  if self.max_idle_sec > 0 &&
    surplus &&
    now - idle.idle_since > self.max_idle_sec.to_int64() * 1000L {
    return true
  }
  false
}

// ---------------------------------------------------------------------------
// Maintenance — ping the idle ones, trim the rest
// ---------------------------------------------------------------------------

///|
/// Run one round of maintenance: ping every idle connection (`Connection::ping`)
/// and drop the ones that are gone, plus the surplus that has been idle long
/// enough to be trimmed (`max_idle_sec`) and the over-age ones (`max_lifetime_sec`
/// — no ping needed, they have to go anyway).  What is left of `min_conn` is
/// pinged and put back.
///
/// A round trip is the only way to learn that the server dropped a connection
/// behind our back: a clean close is not visible until the next I/O, and a
/// black-holed connection only until `read_timeout` expires (`0`, the default,
/// never expires — the ping waits for TCP).  Pinging before a connection is
/// handed out means callers never meet a dead one.
///
/// Connections the round destroyed are reconnected only while the pool is below
/// `min_conn` (bounded by `max_conns`), so the warm set survives while surplus —
/// whether it died or was trimmed — just shrinks the pool.  Healthy connections
/// are always put back untouched.
///
/// This drains the idle queue while it runs, so a concurrent `acquire()` may
/// open a fresh connection instead of reusing an idle one.  A ping on a
/// black-holed connection costs up to `read_timeout` per connection, or as long
/// as TCP takes when `read_timeout` is `0`.
///
/// Runs in the background once `Pool::start_maintenance` has started the loop,
/// and may also be called manually.
pub async fn Pool::maintain(self : Pool) -> Unit noraise {
  let good : Array[IdleConn] = []
  let mut destroyed = 0
  // --- drain, ping, filter --------------------------------------------------
  for ;; {
    let maybe : IdleConn? = self.queue.try_get() catch { _ => break }
    match maybe {
      None => break
      Some(idle) => {
        self.idle_count.val = self.idle_count.val - 1
        let now = @async.now()
        // An over-age connection needs no ping: it has to go anyway, and this
        // round trip saved is the whole point of rotating here instead of on the
        // next request.
        let overage = self.max_lifetime_sec > 0 &&
          now - idle.created_at > self.max_lifetime_sec.to_int64() * 1000L
        // Idle surplus is trimmed here too, and for the same reason: a
        // connection nothing is going to ask for should not be pinged back into
        // the idle list round after round.  `min_conn` is what stays.
        let idle_expired = self.max_idle_sec > 0 &&
          self.count.val > self.min_conn &&
          now - idle.idle_since > self.max_idle_sec.to_int64() * 1000L
        let alive = if overage || idle_expired {
          false
        } else {
          try {
            idle.conn.ping()
            true
          } catch {
            _ => false
          }
        }
        if alive {
          good.push(idle)
        } else {
          idle.conn.close()
          self.count.val = self.count.val - 1
          destroyed = destroyed + 1
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
  // --- reconnect what the round destroyed, up to `min_conn` ------------------
  // Trimming idle surplus cannot get here: it stops at `min_conn`.
  for _ in 0..<destroyed {
    if self.closed.val ||
      self.count.val >= self.min_conn ||
      self.count.val >= self.max_conns {
      break
    }
    let conn = connect(self.conninfo) catch { _ => break }
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

///|
/// Run `Pool::maintain()` every `interval_sec` seconds, in the background.
///
/// Call it once, inside the scope that owns the pool: the loop is a child task
/// of `group`, because the runtime has no detached tasks, so it lives exactly as
/// long as the group does, and stops within ~500ms of `Pool::close()` — unless a
/// round is stuck on a black-holed connection, which can hold it for
/// `read_timeout`, or as long as TCP takes when `read_timeout` is `0`.  Same
/// pattern as `Connection::listen(channel, group)`.
///
/// With the loop running, a connection the server dropped while it sat idle is
/// found and replaced before a caller is handed one, so the `acquire()` that
/// follows has nothing to ping and nothing to reconnect.  A pool without the loop
/// is not broken: its `acquire()` pings whatever has been parked longer than
/// `CHECKOUT_PING_IDLE_MS`, and the request that takes that connection out pays
/// the round trip — or the reconnect, when the ping fails.  What the loop removes
/// is exactly that cost.
///
/// `interval_sec <= 0` makes this a no-op.
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
        self.maintain()
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Acquire
// ---------------------------------------------------------------------------

///|
/// A connection parked longer than this is pinged before it is handed out.
/// `Connection::status` cannot see that the server dropped it — that only shows
/// up on the next I/O — so without a round trip here the dead connection would
/// reach the caller and fail its query.  A connection released a moment ago is
/// almost certainly still good, and paying a round trip for it would be the kind
/// of overhead that makes a pool slower than a plain connection.
const CHECKOUT_PING_IDLE_MS : Int64 = 2000L

///|
/// Decide whether the idle connection `Pool::acquire` just took off the idle
/// queue has to be discarded instead of handed out.
///
/// Two reasons, in this order: `expired` — what the timestamps say, no round trip
/// needed — and then, for a connection parked longer than
/// `CHECKOUT_PING_IDLE_MS`, the checkout ping, which is the only thing that can
/// tell that the server dropped it while it sat parked.
async fn Pool::discard_idle(
  self : Pool,
  idle : IdleConn,
  surplus~ : Bool,
) -> Bool noraise {
  if self.expired(idle, surplus~) {
    return true
  }
  if @async.now() - idle.idle_since <= CHECKOUT_PING_IDLE_MS {
    return false
  }
  try {
    idle.conn.ping()
    false
  } catch {
    _ => true
  }
}

///|

///|
/// Take a connection off the idle queue and decide whether to hand it out.
///
/// `Some` hands the connection on; `None` means it was discarded — expired, or
/// the checkout ping found it gone — and the caller should go and get the next
/// one.  `Pool::acquire` and `Pool::try_acquire` differ only in where they go
/// looking then: the queue (and a wait for a release) versus what is parked right
/// now, and otherwise a fresh connection.
async fn Pool::take_idle(self : Pool, idle : IdleConn) -> PoolConn? noraise {
  self.idle_count.val = self.idle_count.val - 1
  // Dropping this one still leaves `min_conn` connections.
  let surplus = self.count.val - 1 >= self.min_conn
  if self.discard_idle(idle, surplus~) {
    idle.conn.close()
    self.count.val = self.count.val - 1
    None
  } else {
    Some(self.checkout(idle))
  }
}

///|
pub async fn Pool::acquire(self : Pool) -> PoolConn raise PgError {
  self.acquire_count.val = self.acquire_count.val + 1L
  let maybe_idle : IdleConn? = self.queue.try_get() catch {
    _ => raise PgError::ConnectionError("pool closed")
  }
  match maybe_idle {
    Some(idle) =>
      match self.take_idle(idle) {
        Some(pc) => pc
        None => self.acquire()
      }
    None =>
      if self.count.val < self.max_conns {
        self.count.val = self.count.val + 1
        let now = @async.now()
        errdefer {
          // Release the slot reserved above: no connection was created.
          self.count.val = self.count.val - 1
        }
        let conn = connect(self.conninfo)
        PoolConn::{ conn, pool: self, created_at: now, released: Ref(false), }
      } else {
        let wait_start = @async.now()
        self.acquire_wait_count.val = self.acquire_wait_count.val + 1L
        let idle : IdleConn = self.queue.get() catch {
          _ => raise PgError::ConnectionError("pool closed while waiting")
        }
        self.acquire_wait_duration.val = self.acquire_wait_duration.val +
          @async.now() -
          wait_start
        match self.take_idle(idle) {
          Some(pc) => pc
          None => self.acquire()
        }
      }
  }
}

///|
/// Like `Pool::acquire`, except that it never waits for another task to release a
/// connection: `None` means the pool is at `max_conns` with everything checked
/// out, and the only way to get a connection would be to queue up for one.
///
/// It is not non-blocking in the I/O sense — it still awaits the checkout ping
/// (bounded by `read_timeout`) and, while the pool has room, the connect itself.
/// What it never does is wait behind another task.
///
/// Hand the connection back the same way you would one from `acquire()`:
/// `PoolConn::release()` recycles it (and destroys it instead when it is in a bad
/// state), `PoolConn::close()` destroys it.  It is counted in
/// `PoolStats.acquire_count` like `acquire()`; a `None` leaves the wait counters
/// alone, because nothing waited.
///
/// For a caller who would rather skip the work than wait for it:
/// ```
/// guard pool.try_acquire() is Some(conn) else {
///   return   // no connection free — shed the load, serve a cache, retry later
/// }
/// defer conn.release()
/// let names : Array[String] = conn.fetch("SELECT name FROM users")
/// ```
/// `PoolConn` carries the same `query` / `fetch` / `execute` / `begin_tx` as
/// `Pool` does, so nothing is lost but the pool's implicit acquire and release.
pub async fn Pool::try_acquire(self : Pool) -> PoolConn? raise PgError {
  self.acquire_count.val = self.acquire_count.val + 1L
  self.try_take()
}

///|
/// The body of `Pool::try_acquire`: a discarded connection sends it around again,
/// and it stops at `None` rather than at the queue's blocking `get()`.
async fn Pool::try_take(self : Pool) -> PoolConn? raise PgError {
  let maybe_idle : IdleConn? = self.queue.try_get() catch {
    _ => raise PgError::ConnectionError("pool closed")
  }
  match maybe_idle {
    Some(idle) =>
      match self.take_idle(idle) {
        Some(pc) => Some(pc)
        None => self.try_take()
      }
    None =>
      if self.count.val < self.max_conns {
        self.count.val = self.count.val + 1
        let now = @async.now()
        errdefer {
          // Release the slot reserved above: no connection was created.
          self.count.val = self.count.val - 1
        }
        let conn = connect(self.conninfo)
        Some(PoolConn::{
          conn,
          pool: self,
          created_at: now,
          released: Ref(false),
        })
      } else {
        None
      }
  }
}

///|
/// Hand an idle connection to the caller.
fn Pool::checkout(self : Pool, idle : IdleConn) -> PoolConn noraise {
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
  // Drop the connection if it is in a bad state, or too old to be handed out
  // again: an over-lifetime connection is not parked.
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
