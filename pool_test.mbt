///|
// Unit tests for Pool, PoolConn, PoolRows, PoolDbTx.
//
// Requires a live PostgreSQL instance.
// Run with: moon test --target native

let pool_test_conninfo : String = @env.get_env_var("MOONPG_CONNINFO").unwrap_or(
  "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
)

///|
async fn pool_setup(name : String) -> Unit raise PgError {
  let c = connect(pool_test_conninfo)
  c.execute("DROP TABLE IF EXISTS \{name}") |> ignore
  c.execute("CREATE TABLE \{name} (id SERIAL PRIMARY KEY, val INTEGER NOT NULL, note TEXT NOT NULL)") |> ignore
  c.close()
}

///|
fn default_config() -> PoolConfig {
  PoolConfig::new(pool_test_conninfo, max_conns=4, min_idle=0)
}

// ---------------------------------------------------------------------------
// Pool::new / total / close
// ---------------------------------------------------------------------------

///|
async test "pool_new" {
  let pool = Pool::new(default_config())
  assert_eq(pool.total(), 0)
  pool.close()
}

///|
async test "pool_new_with_min_idle" {
  let cfg = PoolConfig::new(pool_test_conninfo, max_conns=4, min_idle=2)
  let pool = Pool::new(cfg)
  assert_eq(pool.total(), 2)
  pool.close()
}

///|
async test "pool_close" {
  let pool = Pool::new(default_config())
  pool.close()
}

// ---------------------------------------------------------------------------
// Pool::acquire / PoolConn::release
// ---------------------------------------------------------------------------

///|
async test "acquire_release" {
  let pool = Pool::new(default_config())
  let pc = pool.acquire()
  assert_eq(pool.total(), 1)
  pc.release()
  assert_eq(pool.total(), 1)
  pool.close()
}

///|
async test "acquire_release_idempotent" {
  let pool = Pool::new(default_config())
  let pc = pool.acquire()
  pc.release()
  pc.release()
  pool.close()
}

///|
async test "acquire_multiple" {
  let pool = Pool::new(default_config())
  let a = pool.acquire()
  let b = pool.acquire()
  assert_eq(pool.total(), 2)
  a.release()
  b.release()
  pool.close()
}

///|
async test "acquire_reuse_released" {
  let cfg = PoolConfig::new(pool_test_conninfo, max_conns=4, min_idle=0)
  let pool = Pool::new(cfg)
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
  let cfg = PoolConfig::new(pool_test_conninfo, max_conns=3, min_idle=0)
  let pool = Pool::new(cfg)
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
  let pool = Pool::new(default_config())
  let pc = pool.acquire()
  assert_eq(pool.total(), 1)
  pc.close()
  assert_eq(pool.total(), 0)
  pool.close()
}

///|
async test "pool_conn_close_after_release_safe" {
  let pool = Pool::new(default_config())
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
  let pool = Pool::new(default_config())
  let pc = pool.acquire()
  pc.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[1, "pc_query"]) |> ignore
  let rows = pc.query("SELECT note FROM \{tbl}")
  assert_true(rows.has_next())
  assert_eq(rows.get_row().get(0), "pc_query")
  rows.close()
  pc.release()
  pool.close()
}

///|
async test "pc_query_rows_close_drains" {
  let tbl = "p_pc_drain"
  pool_setup(tbl)
  let pool = Pool::new(default_config())
  let pc = pool.acquire()
  pc.execute("INSERT INTO \{tbl} (val, note) VALUES (1, 'drain')") |> ignore
  let rows = pc.query("SELECT note FROM \{tbl}")
  rows.close()
  pc.execute("INSERT INTO \{tbl} (val, note) VALUES (2, 'after_drain')") |> ignore
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
  let pool = Pool::new(default_config())
  let pc = pool.acquire()
  pc.execute("INSERT INTO \{tbl} (val, note) VALUES (7, 'pc_q1')") |> ignore
  let row = pc.query_one("SELECT val FROM \{tbl} WHERE note = $1", params=["pc_q1"])
  assert_eq(row.get(0), 7)
  pc.release()
  pool.close()
}

///|
async test "pc_execute" {
  let tbl = "p_pc_exec"
  pool_setup(tbl)
  let pool = Pool::new(default_config())
  let pc = pool.acquire()
  let r = pc.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[10, "pc_exec"])
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
  let pool = Pool::new(default_config())
  let pc = pool.acquire()
  pc.execute("INSERT INTO \{tbl} (val, note) VALUES (1, 'pq')") |> ignore
  pc.release()

  let rows = pool.query("SELECT note FROM \{tbl}")
  assert_true(rows.has_next())
  assert_eq(rows.get_row().get(0), "pq")
  rows.close()
  pool.close()
}

///|
async test "pool_query_one" {
  let tbl = "p_pq1"
  pool_setup(tbl)
  let pool = Pool::new(default_config())
  let pc = pool.acquire()
  pc.execute("INSERT INTO \{tbl} (val, note) VALUES (42, 'pq1')") |> ignore
  pc.release()

  let row = pool.query_one("SELECT val FROM \{tbl} WHERE note = $1", params=["pq1"])
  assert_eq(row.get(0), 42)
  pool.close()
}

///|
async test "pool_query_one_raises_no_rows" {
  let tbl = "p_pq1_empty"
  pool_setup(tbl)
  let pool = Pool::new(default_config())
  try {
    let _ = pool.query_one("SELECT val FROM \{tbl} WHERE note = $1", params=["nobody"])
    fail("expected NoRows")
  } catch {
    e => assert_true(to_repr(e).to_string().contains("NoRows"))
  }
  pool.close()
}

///|
async test "pool_execute" {
  let tbl = "p_exec"
  pool_setup(tbl)
  let pool = Pool::new(default_config())
  let r = pool.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[99, "pool_exec"])
  assert_eq(r.affected_rows(), 1)
  r.close()
  pool.close()
}

///|
async test "pool_execute_error_closes_conn" {
  let pool = Pool::new(default_config())
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
  let pool = Pool::new(default_config())
  let tx = pool.begin_tx()
  tx.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[1, "ptx_commit"]) |> ignore
  tx.commit()

  let rows = pool.query("SELECT note FROM \{tbl}")
  assert_true(rows.has_next())
  assert_eq(rows.get_row().get(0), "ptx_commit")
  rows.close()
  pool.close()
}

///|
async test "pool_begin_tx_rollback" {
  let tbl = "p_ptx_rb"
  pool_setup(tbl)
  let pool = Pool::new(default_config())
  let tx = pool.begin_tx()
  tx.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[99, "ptx_rb"]) |> ignore
  tx.rollback()

  let rows = pool.query("SELECT COUNT(*) FROM \{tbl}")
  assert_true(rows.has_next())
  let count : Int64 = rows.get_row().get(0)
  assert_eq(count, 0L)
  rows.close()
  pool.close()
}

///|
async test "pool_begin_tx_rollback_empty" {
  let tbl = "p_ptx_rb_empty"
  pool_setup(tbl)
  let pool = Pool::new(default_config())
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
  let pool = Pool::new(default_config())
  let tx = pool.begin_tx()
  tx.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[5, "pdbtx_q"]) |> ignore
  let rows = tx.query("SELECT note FROM \{tbl}")
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
  let pool = Pool::new(default_config())
  let tx = pool.begin_tx()
  tx.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[8, "pdbtx_q1"]) |> ignore
  let row = tx.query_one("SELECT val FROM \{tbl} WHERE note = $1", params=["pdbtx_q1"])
  assert_eq(row.get(0), 8)
  tx.commit()
  pool.close()
}

///|
async test "pooldbtx_execute" {
  let tbl = "p_pdbtx_exec"
  pool_setup(tbl)
  let pool = Pool::new(default_config())
  let tx = pool.begin_tx()
  let r = tx.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[3, "pdbtx_exec"])
  assert_eq(r.affected_rows(), 1)
  r.close()
  tx.commit()
  pool.close()
}

///|
async test "pooldbtx_commit_releases_conn" {
  let tbl = "p_pdbtx_rel"
  pool_setup(tbl)
  let pool = Pool::new(default_config())
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
  let pool = Pool::new(default_config())
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
  let pool = Pool::new(default_config())
  let pc = pool.acquire()
  let tx = pc.begin_tx()
  tx.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[1, "pc_dbtx"]) |> ignore
  tx.commit()
  pc.release()
  pool.close()
}

///|
async test "pc_begin_tx_rollback_then_release" {
  let tbl = "p_pc_rb_rel"
  pool_setup(tbl)
  let pool = Pool::new(default_config())
  let pc = pool.acquire()
  let tx = pc.begin_tx()
  tx.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[999, "pc_rollback"]) |> ignore
  tx.rollback()
  pc.release()

  let rows = pool.query("SELECT COUNT(*) FROM \{tbl}")
  assert_true(rows.has_next())
  let count : Int64 = rows.get_row().get(0)
  assert_eq(count, 0L)
  rows.close()
  pool.close()
}

// ---------------------------------------------------------------------------
// begin_func with PoolDbTx
// ---------------------------------------------------------------------------

///|
async test "begin_func_with_pool_success" {
  let tbl = "p_bf_ok"
  pool_setup(tbl)
  let pool = Pool::new(default_config())
  let result = begin_func(pool, async fn(tx) {
    tx.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[1, "bf_pool"]) |> ignore
    100
  })
  assert_eq(result, 100)

  let rows = pool.query("SELECT note FROM \{tbl}")
  assert_true(rows.has_next())
  assert_eq(rows.get_row().get(0), "bf_pool")
  rows.close()
  pool.close()
}

///|
async test "begin_func_with_pool_error_rolls_back" {
  let tbl = "p_bf_err"
  pool_setup(tbl)
  let pool = Pool::new(default_config())
  try {
    let _ = begin_func(pool, async fn(tx) {
      tx.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[1, "should_rollback"]) |> ignore
      fail("intentional failure")
      0
    })
    fail("expected error")
  } catch {
    _ => ()
  }

  let rows = pool.query("SELECT COUNT(*) FROM \{tbl}")
  assert_true(rows.has_next())
  let count : Int64 = rows.get_row().get(0)
  assert_eq(count, 0L)
  rows.close()
  pool.close()
}

// ---------------------------------------------------------------------------
// PoolRows close releases connection
// ---------------------------------------------------------------------------

///|
async test "pool_rows_close_releases" {
  let tbl = "p_rows_rel"
  pool_setup(tbl)
  let pool = Pool::new(default_config())
  let pc = pool.acquire()
  pc.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[1, "rows_rel"]) |> ignore
  let rows = pc.query("SELECT note FROM \{tbl}")
  rows.close()
  pc.release()
  pool.close()
}

///|
async test "pool_query_rows_close_releases" {
  let tbl = "p_q_rows_rel"
  pool_setup(tbl)
  let pool = Pool::new(default_config())
  let pc = pool.acquire()
  pc.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[2, "pool_rows_rel"]) |> ignore
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
  let cfg = PoolConfig::new(pool_test_conninfo, max_conns=2, min_idle=0)
  let pool = Pool::new(cfg)

  for i = 0; i < 5; i = i + 1 {
    pool.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[i, "reuse"]) |> ignore
  }

  let rows = pool.query("SELECT COUNT(*) FROM \{tbl}")
  assert_true(rows.has_next())
  let count : Int64 = rows.get_row().get(0)
  assert_eq(count, 5L)
  rows.close()
  pool.close()
}
