///|
// Unit tests for DbTx, Tx trait, TxBeginner, begin_func.
//
// Requires a live PostgreSQL instance.
// Run with: moon test --target native

let tx_test_conninfo : String = @env.get_env_var("MOONPG_CONNINFO").unwrap_or(
  "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
)

///|
async fn tx_setup(name : String) -> Unit raise PgError {
  let c = connect(tx_test_conninfo)
  c.execute("DROP TABLE IF EXISTS \{name}") |> ignore
  c.execute("CREATE TABLE \{name} (id SERIAL PRIMARY KEY, val INTEGER NOT NULL, note TEXT)") |> ignore
  c.close()
}

// ---------------------------------------------------------------------------
// Connection::begin_tx — basic
// ---------------------------------------------------------------------------

///|
async test "begin_tx_returns_db_tx" {
  let tbl = "tx_basic"
  tx_setup(tbl)
  let c = connect(tx_test_conninfo)
  defer c.close()
  let tx = c.begin_tx()
  tx.execute("INSERT INTO \{tbl} (val, note) VALUES (1, 'tx1')") |> ignore
  tx.commit()
}

///|
async test "begin_tx_commit_persists" {
  let tbl = "tx_commit"
  tx_setup(tbl)
  let c = connect(tx_test_conninfo)
  defer c.close()
  let tx = c.begin_tx()
  tx.execute("INSERT INTO \{tbl} (val, note) VALUES (42, 'committed')") |> ignore
  tx.commit()

  let rows = c.query("SELECT val, note FROM \{tbl}")
  assert_true(rows.has_next())
  let row = rows.get_row()
  assert_eq(row.get(0), 42)
  assert_eq(row.get(1), "committed")
  rows.close()
}

///|
async test "begin_tx_rollback_discards" {
  let tbl = "tx_rollback"
  tx_setup(tbl)
  let c = connect(tx_test_conninfo)
  defer c.close()
  let tx = c.begin_tx()
  tx.execute("INSERT INTO \{tbl} (val, note) VALUES (99, 'rolled_back')") |> ignore
  tx.rollback()

  let rows = c.query("SELECT COUNT(*) FROM \{tbl}")
  assert_true(rows.has_next())
  let row = rows.get_row()
  let count : Int64 = row.get(0)
  assert_eq(count, 0L)
  rows.close()
}

///|
async test "begin_tx_rollback_empty" {
  let tbl = "tx_rb_empty"
  tx_setup(tbl)
  let c = connect(tx_test_conninfo)
  defer c.close()
  let tx = c.begin_tx()
  tx.rollback()
}

///|
async test "begin_tx_commit_empty" {
  let tbl = "tx_commit_empty"
  tx_setup(tbl)
  let c = connect(tx_test_conninfo)
  defer c.close()
  let tx = c.begin_tx()
  tx.commit()
}

// ---------------------------------------------------------------------------
// DbTx: QueryExecutor impl
// ---------------------------------------------------------------------------

///|
async test "dbtx_query" {
  let tbl = "tx_query"
  tx_setup(tbl)
  let c = connect(tx_test_conninfo)
  defer c.close()
  let tx = c.begin_tx()
  tx.execute("INSERT INTO \{tbl} (val, note) VALUES (1, 'q')") |> ignore
  let rows = tx.query("SELECT val, note FROM \{tbl}")
  assert_true(rows.has_next())
  let row = rows.get_row()
  assert_eq(row.get(0), 1)
  assert_eq(row.get(1), "q")
  rows.close()
  tx.commit()
}

///|
async test "dbtx_query_one" {
  let tbl = "tx_q1"
  tx_setup(tbl)
  let c = connect(tx_test_conninfo)
  defer c.close()
  let tx = c.begin_tx()
  tx.execute("INSERT INTO \{tbl} (val, note) VALUES (7, 'q1')") |> ignore
  let row = tx.query_one("SELECT note FROM \{tbl} WHERE val = $1", params=[7])
  assert_eq(row.get(0), "q1")
  tx.commit()
}

///|
async test "dbtx_execute" {
  let tbl = "tx_exec"
  tx_setup(tbl)
  let c = connect(tx_test_conninfo)
  defer c.close()
  let tx = c.begin_tx()
  let r = tx.execute("INSERT INTO \{tbl} (val, note) VALUES ($1, $2)", params=[3, "exec"])
  assert_eq(r.affected_rows(), 1)
  r.close()
  tx.commit()
}

// ---------------------------------------------------------------------------
// DbTx: multiple queries in single tx
// ---------------------------------------------------------------------------

///|
async test "dbtx_multiple_operations" {
  let tbl = "tx_multi"
  tx_setup(tbl)
  let c = connect(tx_test_conninfo)
  defer c.close()
  let tx = c.begin_tx()
  tx.execute("INSERT INTO \{tbl} (val, note) VALUES (10, 'multi1')") |> ignore
  tx.execute("INSERT INTO \{tbl} (val, note) VALUES (20, 'multi2')") |> ignore
  let r = tx.execute("UPDATE \{tbl} SET val = 30 WHERE note = 'multi1'")
  assert_eq(r.affected_rows(), 1)
  r.close()
  tx.commit()

  let rows = c.query("SELECT val FROM \{tbl} ORDER BY val")
  let vals : Array[Int] = []
  while rows.has_next() {
    vals.push(rows.get_row().get(0))
  }
  rows.close()
  assert_eq(vals.length(), 2)
  assert_eq(vals[0], 20)
  assert_eq(vals[1], 30)
}

// ---------------------------------------------------------------------------
// DbTx: tx isolation — data invisible outside before commit
// ---------------------------------------------------------------------------

///|
async test "dbtx_isolation" {
  let tbl = "tx_isolated"
  tx_setup(tbl)
  let c1 = connect(tx_test_conninfo)
  defer c1.close()
  let c2 = connect(tx_test_conninfo)
  defer c2.close()

  let tx = c1.begin_tx()
  tx.execute("INSERT INTO \{tbl} (val, note) VALUES (100, 'isolated')") |> ignore

  let rows = c2.query("SELECT COUNT(*) FROM \{tbl}")
  assert_true(rows.has_next())
  let row = rows.get_row()
  let count : Int64 = row.get(0)
  assert_eq(count, 0L, msg="uncommitted data should be invisible")
  rows.close()

  tx.commit()

  let rows2 = c2.query("SELECT COUNT(*) FROM \{tbl}")
  assert_true(rows2.has_next())
  let row2 = rows2.get_row()
  let count2 : Int64 = row2.get(0)
  assert_eq(count2, 1L, msg="committed data should be visible")
  rows2.close()
}

// ---------------------------------------------------------------------------
// begin_func with DbTx (bare Connection)
// ---------------------------------------------------------------------------

///|
async test "begin_func_success" {
  let tbl = "tx_bf_ok"
  tx_setup(tbl)
  let c = connect(tx_test_conninfo)
  defer c.close()
  let result = begin_func(c.begin_tx(), async fn(tx) {
    tx.execute("INSERT INTO \{tbl} (val, note) VALUES (5, 'func_ok')") |> ignore
    42
  })
  assert_eq(result, 42)

  let rows = c.query("SELECT note FROM \{tbl}")
  assert_true(rows.has_next())
  assert_eq(rows.get_row().get(0), "func_ok")
  rows.close()
}

///|
async test "begin_func_error_rolls_back" {
  let tbl = "tx_bf_err"
  tx_setup(tbl)
  let c = connect(tx_test_conninfo)
  defer c.close()
  try {
    let _ = begin_func(c.begin_tx(), async fn(_tx) {
      fail("intentional failure")
      0
    })
    fail("expected error to propagate")
  } catch {
    _ => ()
  }

  let rows = c.query("SELECT COUNT(*) FROM \{tbl}")
  assert_true(rows.has_next())
  let count : Int64 = rows.get_row().get(0)
  assert_eq(count, 0L)
  rows.close()
}

///|
async test "begin_func_error_with_insert_then_fail" {
  let tbl = "tx_bf_insert_fail"
  tx_setup(tbl)
  let c = connect(tx_test_conninfo)
  defer c.close()
  try {
    let _ = begin_func(c.begin_tx(), async fn(tx) {
      tx.execute("INSERT INTO \{tbl} (val, note) VALUES (999, 'should_rollback')") |> ignore
      fail("mid-tx failure")
      0
    })
    fail("expected error")
  } catch {
    _ => ()
  }

  let rows = c.query("SELECT COUNT(*) FROM \{tbl}")
  assert_true(rows.has_next())
  let count : Int64 = rows.get_row().get(0)
  assert_eq(count, 0L)
  rows.close()
}

// ---------------------------------------------------------------------------
// TxBeginner trait on Connection
// ---------------------------------------------------------------------------

///|
async test "tx_beginner_trait" {
  let tbl = "tx_trait"
  tx_setup(tbl)
  let c = connect(tx_test_conninfo)
  defer c.close()
  let tx : DbTx = TxBeginner::begin_tx(c)
  tx.execute("INSERT INTO \{tbl} (val, note) VALUES (1, 'trait')") |> ignore
  tx.commit()

  let rows = c.query("SELECT note FROM \{tbl}")
  assert_true(rows.has_next())
  assert_eq(rows.get_row().get(0), "trait")
  rows.close()
}

// ---------------------------------------------------------------------------
// DbTx: QueryExecutor via trait
// ---------------------------------------------------------------------------

///|
async test "dbtx_query_via_query_executor_trait" {
  let tbl = "tx_qe_trait"
  tx_setup(tbl)
  let c = connect(tx_test_conninfo)
  defer c.close()
  let tx = c.begin_tx()
  tx.execute("INSERT INTO \{tbl} (val, note) VALUES (88, 'qe_trait')") |> ignore
  let rows : &Rows = QueryExecutor::query(tx, "SELECT note FROM \{tbl}")
  assert_true(rows.has_next())
  assert_eq(rows.get_row().get(0), "qe_trait")
  rows.close()
  tx.commit()
}
