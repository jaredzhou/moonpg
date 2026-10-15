///|
// Unit tests for Pool, PoolConn, PoolRows, PoolDbTx.
//
// Requires a live PostgreSQL instance.
// Run with: moon test --target native

let pool_test_conninfo : String = @env.get_env_var("PGCONN").unwrap_or(
  "postgres://postgres:111111@localhost:5432/postgres",
)

///|
async fn pool_setup(name : String) -> Unit raise @moonpg.PgError {
  let c = @moonpg.connect(pool_test_conninfo)
  c.execute("DROP TABLE IF EXISTS \{name}") |> ignore
  c.execute(
    "CREATE TABLE \{name} (id SERIAL PRIMARY KEY, val INTEGER NOT NULL, note TEXT NOT NULL)",
  )
  |> ignore
  c.close()
}

///|
fn default_config() -> @moonpg.PoolConfig {
  @moonpg.PoolConfig::new(pool_test_conninfo, max_conns=4, min_idle=0)
}

// ---------------------------------------------------------------------------
// Pool::new / total / close
// ---------------------------------------------------------------------------

///|
async test "pool_new" {
  let pool = @moonpg.Pool::new(default_config())
  assert_eq(pool.total(), 0)
  pool.close()
}

///|
async test "pool_new_with_min_idle" {
  let cfg = @moonpg.PoolConfig::new(pool_test_conninfo, max_conns=4, min_idle=2)
  let pool = @moonpg.Pool::new(cfg)
  assert_eq(pool.total(), 2)
  pool.close()
}

///|
async test "pool_close" {
  let pool = @moonpg.Pool::new(default_config())
  pool.close()
}

// ---------------------------------------------------------------------------
// Pool::acquire / PoolConn::release
// ---------------------------------------------------------------------------

///|
async test "acquire_release" {
  let pool = @moonpg.Pool::new(default_config())
  let pc = pool.acquire()
  assert_eq(pool.total(), 1)
  pc.release()
  assert_eq(pool.total(), 1)
  pool.close()
}

///|
async test "acquire_release_idempotent" {
  let pool = @moonpg.Pool::new(default_config())
  let pc = pool.acquire()
  pc.release()
  pc.release()
  pool.close()
}

///|
async test "acquire_multiple" {
  let pool = @moonpg.Pool::new(default_config())
  let a = pool.acquire()
  let b = pool.acquire()
  assert_eq(pool.total(), 2)
  a.release()
  b.release()
  pool.close()
}

///|
async test "acquire_reuse_released" {
  let cfg = @moonpg.PoolConfig::new(pool_test_conninfo, max_conns=4, min_idle=0)
  let pool = @moonpg.Pool::new(cfg)
  let pc1 = pool.acquire()
  assert_eq(pool.total(), 1)
  pc1.release()
  let pc2 = pool.acquire()
  assert_eq(pool.total(), 1)
  pc2.release()
  pool.close()
}

///|
async test "acquire_up_to_max_conns" {
  let cfg = @moonpg.PoolConfig::new(pool_test_conninfo, max_conns=3, min_idle=0)
  let pool = @moonpg.Pool::new(cfg)
  let pc1 = pool.acquire()
  let pc2 = pool.acquire()
  let pc3 = pool.acquire()
  assert_eq(pool.total(), 3)
  pc1.release()
  pc2.release()
  pc3.release()
  pool.close()
}

// ---------------------------------------------------------------------------
// PoolConn::close
// ---------------------------------------------------------------------------

///|
async test "pool_conn_close_destroys" {
  let pool = @moonpg.Pool::new(default_config())
  let pc = pool.acquire()
  assert_eq(pool.total(), 1)
  pc.close()
  assert_eq(pool.total(), 0)
  pool.close()
}

///|
async test "pool_conn_close_after_release_safe" {
  let pool = @moonpg.Pool::new(default_config())
  let pc = pool.acquire()
  pc.release()
  pc.close()
  assert_eq(pool.total(), 0)
  pool.close()
}

// ---------------------------------------------------------------------------
// PoolConn: query (explicit acquire path)
// ---------------------------------------------------------------------------

///|
async test "pc_query_returns_rows" {
  let tbl = "p_pc_query"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  defer pool.close()
  let pc = pool.acquire()
  defer pc.release()
  pc.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[
    1, "pc_query",
  ])
  |> ignore
  let rows = pc.query("SELECT note FROM \{tbl}")
  defer rows.close()
  assert_true(rows.has_next())
  assert_eq(rows.get_row().get(0), "pc_query")
}

///|
async test "pc_query_rows_close_drains" {
  let tbl = "p_pc_drain"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  let pc = pool.acquire()
  pc.execute("INSERT INTO \{tbl} (val, note) VALUES (1, 'drain')") |> ignore
  let rows = pc.query("SELECT note FROM \{tbl}")
  rows.close()
  pc.execute("INSERT INTO \{tbl} (val, note) VALUES (2, 'after_drain')")
  |> ignore
  pc.release()
  pool.close()
}

// ---------------------------------------------------------------------------
// PoolConn: query_one / execute (caller releases)
// ---------------------------------------------------------------------------

///|
async test "pc_query_one" {
  let tbl = "p_pc_q1"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  let pc = pool.acquire()
  pc.execute("INSERT INTO \{tbl} (val, note) VALUES (7, 'pc_q1')") |> ignore
  let row = pc.query_one("SELECT val FROM \{tbl} WHERE note = $1", params=[
    "pc_q1",
  ])
  assert_eq(row.get(0), 7)
  pc.release()
  pool.close()
}

///|
async test "pc_execute" {
  let tbl = "p_pc_exec"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  let pc = pool.acquire()
  let r = pc.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[
    10, "pc_exec",
  ])
  assert_eq(r.affected_rows(), 1)
  r.close()
  pc.release()
  pool.close()
}

// ---------------------------------------------------------------------------
// Pool: QueryExecutor — implicit acquire, auto-release
// ---------------------------------------------------------------------------

///|
async test "pool_query_returns_pool_rows" {
  let tbl = "p_pq_rows"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  defer pool.close()
  let pc = pool.acquire()
  pc.execute("INSERT INTO \{tbl} (val, note) VALUES (1, 'pq')") |> ignore
  pc.release()

  let rows = pool.query("SELECT note FROM \{tbl}")
  defer rows.close()
  assert_true(rows.has_next())
  assert_eq(rows.get_row().get(0), "pq")
}

///|
async test "pool_query_one" {
  let tbl = "p_pq1"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  let pc = pool.acquire()
  pc.execute("INSERT INTO \{tbl} (val, note) VALUES (42, 'pq1')") |> ignore
  pc.release()

  let row = pool.query_one("SELECT val FROM \{tbl} WHERE note = $1", params=[
    "pq1",
  ])
  assert_eq(row.get(0), 42)
  pool.close()
}

///|
async test "pool_query_one_raises_no_rows" {
  let tbl = "p_pq1_empty"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  try {
    let _ = pool.query_one("SELECT val FROM \{tbl} WHERE note = $1", params=[
      "nobody",
    ])
    fail("expected NoRows")
  } catch {
    e => assert_true(Repr(e).to_string().contains("NoRows"))
  }
  pool.close()
}

///|
async test "pool_execute" {
  let tbl = "p_exec"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  let r = pool.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[
    99, "pool_exec",
  ])
  assert_eq(r.affected_rows(), 1)
  r.close()
  pool.close()
}

///|
async test "pool_execute_error_closes_conn" {
  let pool = @moonpg.Pool::new(default_config())
  try {
    pool.execute("BOGUS SQL") |> ignore
    fail("expected error")
  } catch {
    _ => ()
  }
  pool.close()
}

// ---------------------------------------------------------------------------
// Pool::begin_tx → PoolDbTx
// ---------------------------------------------------------------------------

///|
async test "pool_begin_tx_commit" {
  let tbl = "p_ptx_commit"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  defer pool.close()
  let tx = pool.begin_tx()
  @moonpg.QueryExecutor::execute(
    tx,
    "INSERT INTO \{tbl} (val, note) VALUES ($1, $2)",
    params=[1, "ptx_commit"],
  )
  |> ignore
  tx.commit()

  let rows = pool.query("SELECT note FROM \{tbl}")
  defer rows.close()
  assert_true(rows.has_next())
  assert_eq(rows.get_row().get(0), "ptx_commit")
}

///|
async test "pool_begin_tx_rollback" {
  let tbl = "p_ptx_rb"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  defer pool.close()
  let tx = pool.begin_tx()
  @moonpg.QueryExecutor::execute(
    tx,
    "INSERT INTO \{tbl} (val, note) VALUES ($1, $2)",
    params=[99, "ptx_rb"],
  )
  |> ignore
  tx.rollback()

  let rows = pool.query("SELECT COUNT(*) FROM \{tbl}")
  defer rows.close()
  assert_true(rows.has_next())
  let count : Int64 = rows.get_row().get(0)
  assert_eq(count, 0L)
}

///|
async test "pool_begin_tx_rollback_empty" {
  let tbl = "p_ptx_rb_empty"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  let tx = pool.begin_tx()
  tx.rollback()
  pool.close()
}

// ---------------------------------------------------------------------------
// PoolDbTx: QueryExecutor
// ---------------------------------------------------------------------------

///|
async test "pooldbtx_query" {
  let tbl = "p_pdbtx_q"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  let tx = pool.begin_tx()
  @moonpg.QueryExecutor::execute(
    tx,
    "INSERT INTO \{tbl} (val, note) VALUES ($1, $2)",
    params=[5, "pdbtx_q"],
  )
  |> ignore
  let rows = @moonpg.QueryExecutor::query(tx, "SELECT note FROM \{tbl}")
  assert_true(rows.has_next())
  assert_eq(rows.get_row().get(0), "pdbtx_q")
  rows.close()
  tx.commit()
  pool.close()
}

///|
async test "pooldbtx_query_one" {
  let tbl = "p_pdbtx_q1"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  let tx = pool.begin_tx()
  @moonpg.QueryExecutor::execute(
    tx,
    "INSERT INTO \{tbl} (val, note) VALUES ($1, $2)",
    params=[8, "pdbtx_q1"],
  )
  |> ignore
  let row = @moonpg.QueryExecutor::query_one(
    tx,
    "SELECT val FROM \{tbl} WHERE note = $1",
    params=["pdbtx_q1"],
  )
  assert_eq(row.get(0), 8)
  tx.commit()
  pool.close()
}

///|
async test "pooldbtx_execute" {
  let tbl = "p_pdbtx_exec"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  let tx = pool.begin_tx()
  let r = @moonpg.QueryExecutor::execute(
    tx,
    "INSERT INTO \{tbl} (val, note) VALUES ($1, $2)",
    params=[3, "pdbtx_exec"],
  )
  assert_eq(r.affected_rows(), 1)
  r.close()
  tx.commit()
  pool.close()
}

///|
async test "pooldbtx_commit_releases_conn" {
  let tbl = "p_pdbtx_rel"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  let initial = pool.total()

  let tx = pool.begin_tx()
  assert_eq(pool.total(), initial + 1)
  tx.commit()
  assert_eq(pool.total(), initial + 1)
  pool.close()
}

///|
async test "pooldbtx_rollback_releases_conn" {
  let tbl = "p_pdbtx_rb_rel"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  let initial = pool.total()

  let tx = pool.begin_tx()
  assert_eq(pool.total(), initial + 1)
  tx.rollback()
  assert_eq(pool.total(), initial + 1)
  pool.close()
}

// ---------------------------------------------------------------------------
// PoolConn::begin_tx (caller releases after tx)
// ---------------------------------------------------------------------------

///|
async test "pc_begin_tx_returns_dbtx" {
  let tbl = "p_pc_dbtx"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  let pc = pool.acquire()
  let tx = pc.begin_tx()
  @moonpg.QueryExecutor::execute(
    tx,
    "INSERT INTO \{tbl} (val, note) VALUES ($1, $2)",
    params=[1, "pc_dbtx"],
  )
  |> ignore
  tx.commit()
  pc.release()
  pool.close()
}

///|
async test "pc_begin_tx_rollback_then_release" {
  let tbl = "p_pc_rb_rel"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  defer pool.close()
  let pc = pool.acquire()
  let tx = pc.begin_tx()
  @moonpg.QueryExecutor::execute(
    tx,
    "INSERT INTO \{tbl} (val, note) VALUES ($1, $2)",
    params=[999, "pc_rollback"],
  )
  |> ignore
  tx.rollback()
  pc.release()

  let rows = pool.query("SELECT COUNT(*) FROM \{tbl}")
  defer rows.close()
  assert_true(rows.has_next())
  let count : Int64 = rows.get_row().get(0)
  assert_eq(count, 0L)
}

// ---------------------------------------------------------------------------
// begin_func with PoolDbTx
// ---------------------------------------------------------------------------

///|
async test "begin_func_with_pool_success" {
  let tbl = "p_bf_ok"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  defer pool.close()
  let result = @moonpg.begin_func(pool, async fn(tx) {
    @moonpg.QueryExecutor::execute(
      tx,
      "INSERT INTO \{tbl} (val, note) VALUES ($1, $2)",
      params=[1, "bf_pool"],
    )
    |> ignore
    100
  })
  assert_eq(result, 100)

  let rows = pool.query("SELECT note FROM \{tbl}")
  defer rows.close()
  assert_true(rows.has_next())
  assert_eq(rows.get_row().get(0), "bf_pool")
}

///|
async test "begin_func_with_pool_error_rolls_back" {
  let tbl = "p_bf_err"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  defer pool.close()
  try {
    let _ = @moonpg.begin_func(pool, async fn(tx) {
      @moonpg.QueryExecutor::execute(
        tx,
        "INSERT INTO \{tbl} (val, note) VALUES ($1, $2)",
        params=[1, "should_rollback"],
      )
      |> ignore
      fail("intentional failure")
      0
    })
    fail("expected error")
  } catch {
    _ => ()
  }

  let rows = pool.query("SELECT COUNT(*) FROM \{tbl}")
  defer rows.close()
  assert_true(rows.has_next())
  let count : Int64 = rows.get_row().get(0)
  assert_eq(count, 0L)
}

// ---------------------------------------------------------------------------
// PoolRows close releases connection
// ---------------------------------------------------------------------------

///|
async test "pool_rows_close_releases" {
  let tbl = "p_rows_rel"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  let pc = pool.acquire()
  pc.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[
    1, "rows_rel",
  ])
  |> ignore
  let rows = pc.query("SELECT note FROM \{tbl}")
  rows.close()
  pc.release()
  pool.close()
}

///|
async test "pool_query_rows_close_releases" {
  let tbl = "p_q_rows_rel"
  pool_setup(tbl)
  let pool = @moonpg.Pool::new(default_config())
  let pc = pool.acquire()
  pc.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[
    2, "pool_rows_rel",
  ])
  |> ignore
  pc.release()

  let initial = pool.total()
  let rows = pool.query("SELECT note FROM \{tbl}")
  rows.close()
  assert_eq(pool.total(), initial)
  pool.close()
}

// ---------------------------------------------------------------------------
// Connections are actually reused
// ---------------------------------------------------------------------------

///|
async test "pool_reuse_across_operations" {
  let tbl = "p_reuse"
  pool_setup(tbl)
  let cfg = @moonpg.PoolConfig::new(pool_test_conninfo, max_conns=2, min_idle=0)
  let pool = @moonpg.Pool::new(cfg)
  defer pool.close()

  for i = 0; i < 5; i = i + 1 {
    pool.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[
      i, "reuse",
    ])
    |> ignore
  }

  let rows = pool.query("SELECT COUNT(*) FROM \{tbl}")
  defer rows.close()
  assert_true(rows.has_next())
  let count : Int64 = rows.get_row().get(0)
  assert_eq(count, 5L)
}

// ---------------------------------------------------------------------------
// Lazy expiry — idle connections are checked when the pool is used
// ---------------------------------------------------------------------------

///|
async test "pool_acquire_drops_expired_idle" {
  let cfg = @moonpg.PoolConfig::new(
    pool_test_conninfo,
    max_conns=4,
    min_idle=0,
    max_idle_sec=1,
  )
  let pool = @moonpg.Pool::new(cfg)
  defer pool.close()

  let p1 = pool.acquire()
  let pid1 : Int32 = p1.query_one("SELECT pg_backend_pid()").get(0)
  p1.release()
  assert_eq(pool.total(), 1)

  // p1 has now been idle past max_idle_sec.  Nothing runs in the background,
  // so the pool only notices here: it drops p1 and opens a fresh connection.
  @async.sleep(1400)
  let p2 = pool.acquire()
  let pid2 : Int32 = p2.query_one("SELECT pg_backend_pid()").get(0)
  assert_true(pid1 != pid2)
  assert_eq(pool.total(), 1)
  p2.release()
}

///|
// `max_idle_sec` never trims the warm `min_idle` connections: a live
// connection is reused, not dropped and immediately reconnected.
async test "pool_keeps_warm_min_idle_connection" {
  let cfg = @moonpg.PoolConfig::new(
    pool_test_conninfo,
    max_conns=4,
    min_idle=1,
    max_idle_sec=1,
  )
  let pool = @moonpg.Pool::new(cfg)
  defer pool.close()

  let p1 = pool.acquire()
  let pid1 : Int32 = p1.query_one("SELECT pg_backend_pid()").get(0)
  p1.release()
  assert_eq(pool.total(), 1)

  // Idle past max_idle_sec, but it is the last idle connection and min_idle=1,
  // so it is kept: same backend, no reconnect.
  @async.sleep(1400)
  let p2 = pool.acquire()
  let pid2 : Int32 = p2.query_one("SELECT pg_backend_pid()").get(0)
  assert_eq(pid1, pid2)
  assert_eq(pool.total(), 1)
  p2.release()
}

///|
// With more connections than min_idle, the idle ones past max_idle_sec are
// trimmed on the next acquire, down to min_idle — and no further.
async test "pool_acquire_trims_idle_surplus_down_to_min_idle" {
  let cfg = @moonpg.PoolConfig::new(
    pool_test_conninfo,
    max_conns=5,
    min_idle=2,
    max_idle_sec=1,
  )
  let pool = @moonpg.Pool::new(cfg)
  defer pool.close()

  let held : Array[@moonpg.PoolConn] = []
  for _ in 0..<5 {
    held.push(pool.acquire())
  }
  assert_eq(pool.total(), 5)
  for p in held {
    p.release()
  }
  assert_eq(pool.idle(), 5)

  // All five are now past max_idle_sec.  This acquire drops the surplus ones
  // (down to min_idle = 2) and checks one of the survivors out.
  @async.sleep(1400)
  let p = pool.acquire()
  assert_eq(pool.total(), 2)
  assert_eq(pool.idle(), 1)
  p.release()
  assert_eq(pool.total(), 2)
}

// Same server, but with a short client-side read timeout (URI conn string).

///|
fn pool_with_read_timeout(conninfo : String, secs : Int32) -> String {
  match conninfo.find("?") {
    Some(_) => "\{conninfo}&read_timeout=\{secs}"
    None => "\{conninfo}?read_timeout=\{secs}"
  }
}

///|
// A query that trips the read timeout must not poison the pool: the connection
// is destroyed and the next request gets a fresh one.
async test "pool_recovers_after_read_timeout" {
  let cfg = @moonpg.PoolConfig::new(
    pool_with_read_timeout(pool_test_conninfo, 1),
    max_conns=2,
    min_idle=0,
  )
  let pool = @moonpg.Pool::new(cfg)
  defer pool.close()

  let timed_out = try {
    pool.execute("SELECT pg_sleep(3)") |> ignore
    false
  } catch {
    @moonpg.PgError::ConnectionError(_) => true
    _ => false
  }
  assert_true(timed_out, msg="expected a read timeout error")
  assert_eq(pool.total(), 0)

  pool.execute("SELECT 1") |> ignore
  assert_eq(pool.total(), 1)
}

// ---------------------------------------------------------------------------
// PoolStats
// ---------------------------------------------------------------------------

///|
async test "pool_stats_counters" {
  let cfg = @moonpg.PoolConfig::new(pool_test_conninfo, max_conns=4, min_idle=0)
  let pool = @moonpg.Pool::new(cfg)
  defer pool.close()

  let s0 = pool.stats()
  assert_eq(s0.total_connections, 0)
  assert_eq(s0.idle_connections, 0)
  assert_eq(s0.active_connections, 0)

  let pc = pool.acquire()
  let s1 = pool.stats()
  assert_eq(s1.total_connections, 1)
  assert_eq(s1.idle_connections, 0)
  assert_eq(s1.active_connections, 1)
  assert_eq(s1.acquire_count, 1L)

  pc.release()
  let s2 = pool.stats()
  assert_eq(s2.total_connections, 1)
  assert_eq(s2.idle_connections, 1)
  assert_eq(s2.active_connections, 0)
}

///|
async test "pool_stats_acquire_wait" {
  let cfg = @moonpg.PoolConfig::new(pool_test_conninfo, max_conns=2, min_idle=2)
  let pool = @moonpg.Pool::new(cfg)
  defer pool.close()

  let p1 = pool.acquire()
  let p2 = pool.acquire()

  // Third acquire will wait until one is released
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      @async.sleep(200)
      p1.release()
    }
    let p3 = pool.acquire()
    p3.release()
  }

  let stats = pool.stats()
  assert_true(stats.acquire_wait_count >= 1L)
  p2.release()
}

// ---------------------------------------------------------------------------
// Maintenance — ping the idle connections
// ---------------------------------------------------------------------------

///|
// Kill a backend from a separate connection: the pool connection dies while it
// sits idle and, being a clean close, is only noticed on the next use.
async fn pool_kill_backend(pid : Int32) -> Unit {
  let killer = @moonpg.connect(pool_test_conninfo)
  killer.execute("SELECT pg_terminate_backend($1)", params=[pid]) |> ignore
  killer.close()
  @async.sleep(100)
}

///|
async test "pool_maintain_drops_dead_conn" {
  let cfg = @moonpg.PoolConfig::new(pool_test_conninfo, max_conns=2, min_idle=0)
  let pool = @moonpg.Pool::new(cfg)
  defer pool.close()

  let p1 = pool.acquire()
  let pid1 : Int32 = p1.query_one("SELECT pg_backend_pid()").get(0)
  p1.release()
  assert_eq(pool.idle(), 1)

  pool_kill_backend(pid1)
  // Maintenance is the only thing that can discover this; min_idle = 0 means
  // the dead connection is not replaced.
  pool.maintain()
  assert_eq(pool.idle(), 0)
  assert_eq(pool.total(), 0)
}

///|
async test "pool_maintain_replaces_warm_min_idle" {
  let cfg = @moonpg.PoolConfig::new(pool_test_conninfo, max_conns=2, min_idle=1)
  let pool = @moonpg.Pool::new(cfg)
  defer pool.close()

  let p1 = pool.acquire()
  let pid1 : Int32 = p1.query_one("SELECT pg_backend_pid()").get(0)
  p1.release()

  pool_kill_backend(pid1)
  pool.maintain()
  // The dead connection was replaced, not just dropped: min_idle = 1.
  assert_eq(pool.idle(), 1)
  assert_eq(pool.total(), 1)

  let p2 = pool.acquire()
  let pid2 : Int32 = p2.query_one("SELECT pg_backend_pid()").get(0)
  assert_true(pid1 != pid2)
  p2.release()
}

///|
// One call — `start_maintenance(group~)` — and the pool maintains itself: a
// connection the server dropped while it sat idle is replaced before a caller
// asks for it.
async test "pool_maintenance_replaces_dead_conn" {
  let cfg = @moonpg.PoolConfig::new(pool_test_conninfo, max_conns=2, min_idle=1)

  @async.with_task_group() <| group => {
    // `group~` at construction: the pool maintains itself from here on.
    let pool = @moonpg.Pool::new(cfg, group~, ping_interval_sec=1)
    let p1 = pool.acquire()
    let pid1 : Int32 = p1.query_one("SELECT pg_backend_pid()").get(0)
    p1.release()

    pool_kill_backend(pid1)
    // The background loop pings within ~1.5s and replaces the dead connection.
    @async.sleep(2500)
    assert_true(pool.idle() >= 1, msg="expected the loop to reconnect")

    let p2 = pool.acquire()
    let pid2 : Int32 = p2.query_one("SELECT pg_backend_pid()").get(0)
    assert_true(pid1 != pid2)
    p2.release()
    // `close()` stops the loop; the group then exits on its own.
    pool.close()
  }
}

///|
// `start_maintenance` is the escape hatch for a group whose result type is not
// `Unit` (the constructor's `group?` is typed `TaskGroup[Unit]`).
async test "pool_start_maintenance_non_unit_group" {
  let cfg = @moonpg.PoolConfig::new(pool_test_conninfo, max_conns=2, min_idle=0)
  let done : String = @async.with_task_group() <| group => {
    let pool = @moonpg.Pool::new(cfg)
    pool.start_maintenance(group~, interval_sec=1)
    @async.sleep(600)
    pool.close()
    "ok"
  }
  assert_eq(done, "ok")
}
