///|
// Unit tests for Connection, ConnRows, Row, ExecResult, QueryExecutor.
// Run with: moon test --target native conn_test.mbt

let test_conninfo : String = @env.get_env_var("MOONPG_CONNINFO").unwrap_or(
  "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
)

// Helper: create a fresh table with a unique name, return the name.
// Each test gets its own table to avoid inter-test data pollution.

///|
async fn setup_table(name : String) -> Unit raise PgError {
  let c = connect(test_conninfo)
  c.execute("DROP TABLE IF EXISTS \{name}") |> ignore
  c.execute(
    "CREATE TABLE \{name} (id SERIAL PRIMARY KEY, num INTEGER NOT NULL, name TEXT NOT NULL, flag BOOLEAN NOT NULL)",
  )
  |> ignore
  c.close()
}

// Helper: wrap every test to print the exact error

///|
async fn[T] log_err(name : String, f : async () -> T raise Error) -> Unit {
  try f() |> ignore catch {
    e => println("[FAIL] \{name}: \{to_repr(e)}")
  }
}

// ---------------------------------------------------------------------------

///|
async test "connect_ok" {
  log_err("connect_ok", async fn() {
    let c = connect(test_conninfo)
    c.close()
  })
}

///|
async test "connect_invalid_host" {
  try {
    let _ = connect("postgres://no.such.host:5432/db")
    fail("expected connection error")
  } catch {
    _ => ()
  }
}

///|
async test "status_ok_after_connect" {
  log_err("status_ok_after_connect", async fn() {
    let c = connect(test_conninfo)
    match c.status() {
      ConnStatus::OK => ()
      _ => fail("expected OK")
    }
    c.close()
  })
}

///|
async test "status_bad_after_close" {
  log_err("status_bad_after_close", async fn() {
    let c = connect(test_conninfo)
    c.close()
    match c.status() {
      ConnStatus::Bad => ()
      _ => fail("expected Bad")
    }
  })
}

///|
async test "server_version_positive" {
  log_err("server_version_positive", async fn() {
    let c = connect(test_conninfo)
    assert_true(c.server_version() > 0)
    c.close()
  })
}

// ---------------------------------------------------------------------------
// execute
// ---------------------------------------------------------------------------

///|
async test "execute_ddl" {
  log_err("execute_ddl", async fn() {
    let c = connect(test_conninfo)
    c.execute("DROP TABLE IF EXISTS moonpg_exec_ddl") |> ignore
    let r = c.execute(
      "CREATE TABLE moonpg_exec_ddl (id SERIAL PRIMARY KEY, val TEXT)",
    )
    assert_eq(r.affected_rows(), 0)
    r.close()
    c.close()
  })
}

///|
async test "execute_insert_affected_rows" {
  log_err("execute_insert_affected_rows", async fn() {
    let tbl = "t_insert"
    setup_table(tbl)
    let c = connect(test_conninfo)
    let r = c.execute(
      "INSERT INTO \{tbl} (num, name, flag) VALUES ($1, $2, $3)",
      params=[1, "hello", true],
    )
    assert_eq(r.affected_rows(), 1)
    r.close()
    c.close()
  })
}

///|
async test "execute_update_affected_rows" {
  log_err("execute_update_affected_rows", async fn() {
    let tbl = "t_update"
    setup_table(tbl)
    let c = connect(test_conninfo)
    c.execute("INSERT INTO \{tbl} (num, name, flag) VALUES (1, 'x', true)")
    |> ignore
    let r = c.execute("UPDATE \{tbl} SET name = 'y'")
    assert_eq(r.affected_rows(), 1)
    r.close()
    c.close()
  })
}

///|
async test "execute_delete_affected_rows" {
  log_err("execute_delete_affected_rows", async fn() {
    let tbl = "t_delete"
    setup_table(tbl)
    let c = connect(test_conninfo)
    c.execute("INSERT INTO \{tbl} (num, name, flag) VALUES (1, 'x', true)")
    |> ignore
    let r = c.execute("DELETE FROM \{tbl}")
    assert_eq(r.affected_rows(), 1)
    r.close()
    c.close()
  })
}

///|
async test "execute_multi_insert_affected_rows" {
  log_err("execute_multi_insert_affected_rows", async fn() {
    let tbl = "t_multi"
    setup_table(tbl)
    let c = connect(test_conninfo)
    let r = c.execute(
      "INSERT INTO \{tbl} (num, name, flag) VALUES (1, 'a', true), (2, 'b', false), (3, 'c', true)",
    )
    assert_eq(r.affected_rows(), 3)
    r.close()
    c.close()
  })
}

///|
async test "execute_with_params_int_string_bool" {
  log_err("execute_with_params_int_string_bool", async fn() {
    let tbl = "t_params"
    setup_table(tbl)
    let c = connect(test_conninfo)
    let r = c.execute(
      "INSERT INTO \{tbl} (num, name, flag) VALUES ($1, $2, $3)",
      params=[42, "params_test", false],
    )
    assert_eq(r.affected_rows(), 1)
    r.close()
    c.close()
  })
}

///|
async test "execute_with_params_int64" {
  log_err("execute_with_params_int64", async fn() {
    let tbl = "t_int64"
    let c = connect(test_conninfo)
    c.execute("DROP TABLE IF EXISTS \{tbl}") |> ignore
    c.execute(
      "CREATE TABLE \{tbl} (id SERIAL PRIMARY KEY, big_val BIGINT NOT NULL)",
    )
    |> ignore
    let r = c.execute("INSERT INTO \{tbl} (big_val) VALUES ($1)", params=[
      9223372036854775807L,
    ])
    assert_eq(r.affected_rows(), 1)
    r.close()
    c.close()
  })
}

///|
async test "execute_with_params_nullable_none" {
  log_err("execute_with_params_nullable_none", async fn() {
    let tbl = "t_null_none"
    let c = connect(test_conninfo)
    c.execute("DROP TABLE IF EXISTS \{tbl}") |> ignore
    c.execute("CREATE TABLE \{tbl} (id SERIAL PRIMARY KEY, email TEXT)")
    |> ignore
    let email_none : String? = None
    let r = c.execute("INSERT INTO \{tbl} (email) VALUES ($1)", params=[
      email_none,
    ])
    assert_eq(r.affected_rows(), 1)
    r.close()
    c.close()
  })
}

///|
async test "execute_with_params_nullable_some" {
  log_err("execute_with_params_nullable_some", async fn() {
    let tbl = "t_null_some"
    let c = connect(test_conninfo)
    c.execute("DROP TABLE IF EXISTS \{tbl}") |> ignore
    c.execute("CREATE TABLE \{tbl} (id SERIAL PRIMARY KEY, email TEXT)")
    |> ignore
    let email_some : String? = Some("a@b.com")
    let r = c.execute("INSERT INTO \{tbl} (email) VALUES ($1)", params=[
      email_some,
    ])
    assert_eq(r.affected_rows(), 1)
    r.close()
    c.close()
  })
}

///|
async test "execute_error_raises" {
  log_err("execute_error_raises", async fn() {
    let c = connect(test_conninfo)
    try {
      c.execute("BOGUS SQL STATEMENT") |> ignore
      fail("expected query error")
    } catch {
      _ => ()
    }
    c.close()
  })
}

// ---------------------------------------------------------------------------

///|
async test "exec_result_close" {
  log_err("exec_result_close", async fn() {
    let tbl = "t_exec_close"
    setup_table(tbl)
    let c = connect(test_conninfo)
    let r = c.execute(
      "INSERT INTO \{tbl} (num, name, flag) VALUES (1, 'x', true)",
    )
    r.close()
    c.close()
  })
}

// ---------------------------------------------------------------------------
// query
// ---------------------------------------------------------------------------

///|
async test "query_no_rows" {
  log_err("query_no_rows", async fn() {
    let tbl = "t_q_empty"
    setup_table(tbl)
    let c = connect(test_conninfo)
    let rows = c.query("SELECT * FROM \{tbl}")
    assert_false(rows.has_next())
    rows.close()
    c.close()
  })
}

///|
async test "query_single_row" {
  log_err("query_single_row", async fn() {
    let tbl = "t_q_one"
    setup_table(tbl)
    let c = connect(test_conninfo)
    c.execute("INSERT INTO \{tbl} (num, name, flag) VALUES (7, 'solo', true)")
    |> ignore
    let rows = c.query("SELECT num, name, flag FROM \{tbl}")
    assert_true(rows.has_next())
    let row = rows.get_row()
    assert_eq(row.get(0), 7)
    assert_eq(row.get(1), "solo")
    assert_eq(row.get(2), true)
    assert_false(rows.has_next())
    rows.close()
    c.close()
  })
}

///|
async test "query_multiple_rows" {
  log_err("query_multiple_rows", async fn() {
    let tbl = "t_q_multi"
    setup_table(tbl)
    let c = connect(test_conninfo)
    c.execute(
      "INSERT INTO \{tbl} (num, name, flag) VALUES (1, 'a', true), (2, 'b', false), (3, 'c', true)",
    )
    |> ignore
    let rows = c.query("SELECT name FROM \{tbl} ORDER BY num")
    let names : Array[String] = []
    while rows.has_next() {
      let row = rows.get_row()
      names.push(row.get(0))
    }
    rows.close()
    assert_eq(names.length(), 3)
    assert_eq(names[0], "a")
    assert_eq(names[1], "b")
    assert_eq(names[2], "c")
    c.close()
  })
}

///|
async test "query_columns" {
  log_err("query_columns", async fn() {
    let tbl = "t_q_cols"
    setup_table(tbl)
    let c = connect(test_conninfo)
    let rows = c.query("SELECT num, name, flag FROM \{tbl}")
    let cols = rows.columns()
    rows.close()
    assert_eq(cols.length(), 3)
    assert_eq(cols[0].name, "num")
    assert_eq(cols[1].name, "name")
    assert_eq(cols[2].name, "flag")
    c.close()
  })
}

///|
async test "query_param_types" {
  log_err("query_param_types", async fn() {
    let tbl = "t_q_params"
    setup_table(tbl)
    let c = connect(test_conninfo)
    c.execute("INSERT INTO \{tbl} (num, name, flag) VALUES ($1, $2, $3)", params=[
      42, "typed", true,
    ])
    |> ignore
    let rows = c.query("SELECT num, name, flag FROM \{tbl} WHERE num = $1", params=[
      42,
    ])
    assert_true(rows.has_next())
    let row = rows.get_row()
    assert_eq(row.get(0), 42)
    assert_eq(row.get(1), "typed")
    assert_eq(row.get(2), true)
    rows.close()
    c.close()
  })
}

///|
async test "query_double_close_safe" {
  log_err("query_double_close_safe", async fn() {
    let tbl = "t_q_dbl"
    setup_table(tbl)
    let c = connect(test_conninfo)
    let rows = c.query("SELECT 1")
    rows.close()
    c.close()
  })
}

// ---------------------------------------------------------------------------
// Row
// ---------------------------------------------------------------------------

///|
async test "row_get_by_index" {
  log_err("row_get_by_index", async fn() {
    let tbl = "t_row_idx"
    setup_table(tbl)
    let c = connect(test_conninfo)
    c.execute("INSERT INTO \{tbl} (num, name, flag) VALUES (99, 'idx', false)")
    |> ignore
    let rows = c.query("SELECT num, name, flag FROM \{tbl}")
    assert_true(rows.has_next())
    let row = rows.get_row()
    assert_eq(row.get(0), 99)
    assert_eq(row.get(1), "idx")
    assert_eq(row.get(2), false)
    rows.close()
    c.close()
  })
}

///|
async test "row_get_by_name" {
  log_err("row_get_by_name", async fn() {
    let tbl = "t_row_name"
    setup_table(tbl)
    let c = connect(test_conninfo)
    c.execute(
      "INSERT INTO \{tbl} (num, name, flag) VALUES (55, 'byname', true)",
    )
    |> ignore
    let rows = c.query("SELECT num, name, flag FROM \{tbl}")
    assert_true(rows.has_next())
    let row = rows.get_row()
    assert_eq(row.get_by_name("num"), 55)
    assert_eq(row.get_by_name("name"), "byname")
    assert_eq(row.get_by_name("flag"), true)
    rows.close()
    c.close()
  })
}

///|
async test "row_get_by_name_missing_raises" {
  log_err("row_get_by_name_missing_raises", async fn() {
    let tbl = "t_row_miss"
    setup_table(tbl)
    let c = connect(test_conninfo)
    c.execute("INSERT INTO \{tbl} (num, name, flag) VALUES (1, 'x', true)")
    |> ignore
    let rows = c.query("SELECT num FROM \{tbl}")
    assert_true(rows.has_next())
    let row = rows.get_row()
    try {
      let _ : Int = row.get_by_name("nonexistent")
      fail("expected missing column to raise")
    } catch {
      _ => ()
    }
    rows.close()
    c.close()
  })
}

///|
async test "row_columns" {
  log_err("row_columns", async fn() {
    let tbl = "t_row_cols"
    setup_table(tbl)
    let c = connect(test_conninfo)
    // Need a row to call row.columns()
    c.execute("INSERT INTO \{tbl} (num, name, flag) VALUES (1, 'a', true)")
    |> ignore
    let rows = c.query("SELECT num, name FROM \{tbl}")
    assert_true(rows.has_next())
    let row = rows.get_row()
    let cols = row.columns()
    assert_eq(cols.length(), 2)
    assert_eq(cols[0].name, "num")
    rows.close()
    c.close()
  })
}

// ---------------------------------------------------------------------------
// nullable
// ---------------------------------------------------------------------------

///|
async test "row_null_read_raises_for_non_optional" {
  log_err("row_null_read_raises_for_non_optional", async fn() {
    let tbl = "t_null_raise"
    let c = connect(test_conninfo)
    c.execute("DROP TABLE IF EXISTS \{tbl}") |> ignore
    c.execute("CREATE TABLE \{tbl} (id SERIAL PRIMARY KEY, email TEXT)")
    |> ignore
    c.execute("INSERT INTO \{tbl} (email) VALUES (NULL)") |> ignore
    let rows = c.query("SELECT email FROM \{tbl}")
    assert_true(rows.has_next())
    let row = rows.get_row()
    try {
      let _ : String = row.get(0)
      fail("expected NULL -> String to raise")
    } catch {
      _ => ()
    }
    rows.close()
    c.close()
  })
}

///|
async test "row_null_read_optional" {
  log_err("row_null_read_optional", async fn() {
    let tbl = "t_null_opt"
    let c = connect(test_conninfo)
    c.execute("DROP TABLE IF EXISTS \{tbl}") |> ignore
    c.execute("CREATE TABLE \{tbl} (id SERIAL PRIMARY KEY, email TEXT)")
    |> ignore
    c.execute("INSERT INTO \{tbl} (email) VALUES (NULL)") |> ignore
    let rows = c.query("SELECT email FROM \{tbl}")
    assert_true(rows.has_next())
    let row = rows.get_row()
    let email : String? = row.get(0)
    match email {
      Some(_) => fail("expected None")
      None => ()
    }
    rows.close()
    c.close()
  })
}

///|
async test "row_optional_some" {
  log_err("row_optional_some", async fn() {
    let tbl = "t_opt_some"
    let c = connect(test_conninfo)
    c.execute("DROP TABLE IF EXISTS \{tbl}") |> ignore
    c.execute("CREATE TABLE \{tbl} (id SERIAL PRIMARY KEY, email TEXT)")
    |> ignore
    c.execute("INSERT INTO \{tbl} (email) VALUES ('hello@x.com')") |> ignore
    let rows = c.query("SELECT email FROM \{tbl}")
    assert_true(rows.has_next())
    let row = rows.get_row()
    let email : String? = row.get(0)
    match email {
      Some(s) => assert_eq(s, "hello@x.com")
      None => fail("expected Some")
    }
    rows.close()
    c.close()
  })
}

// ---------------------------------------------------------------------------
// query_one
// ---------------------------------------------------------------------------

///|
async test "query_one_success" {
  log_err("query_one_success", async fn() {
    let tbl = "t_q1_ok"
    setup_table(tbl)
    let c = connect(test_conninfo)
    c.execute("INSERT INTO \{tbl} (num, name, flag) VALUES (7, 'one', true)")
    |> ignore
    let row = c.query_one("SELECT num, name FROM \{tbl} WHERE name = $1", params=[
      "one",
    ])
    assert_eq(row.get(0), 7)
    assert_eq(row.get(1), "one")
    c.close()
  })
}

///|
async test "query_one_raises_no_rows" {
  log_err("query_one_raises_no_rows", async fn() {
    let tbl = "t_q1_empty"
    setup_table(tbl)
    let c = connect(test_conninfo)
    try {
      let _ = c.query_one("SELECT num FROM \{tbl} WHERE name = $1", params=[
        "nobody",
      ])
      fail("expected NoRows")
    } catch {
      e => assert_true(to_repr(e).to_string().contains("NoRows"))
    }
    c.close()
  })
}

///|
async test "query_one_returns_first_of_many" {
  log_err("query_one_returns_first_of_many", async fn() {
    let tbl = "t_q1_multi"
    setup_table(tbl)
    let c = connect(test_conninfo)
    c.execute(
      "INSERT INTO \{tbl} (num, name, flag) VALUES (1, 'first', true), (2, 'second', false)",
    )
    |> ignore
    let row = c.query_one("SELECT name FROM \{tbl} ORDER BY num")
    assert_eq(row.get(0), "first")
    c.close()
  })
}

// ---------------------------------------------------------------------------

///|
async test "query_returns_rows_trait_object" {
  log_err("query_returns_rows_trait_object", async fn() {
    let tbl = "t_trait"
    setup_table(tbl)
    let c = connect(test_conninfo)
    c.execute("INSERT INTO \{tbl} (num, name, flag) VALUES (1, 'trait', true)")
    |> ignore
    let rows : &Rows = c.query("SELECT name FROM \{tbl}")
    assert_true(rows.has_next())
    let row = rows.get_row()
    let n : String = row.get(0)
    assert_eq(n, "trait")
    rows.close()
    c.close()
  })
}

///|
async test "text_utf8_round_trip" {
  log_err("text_utf8_round_trip", async fn() {
    let tbl = "t_utf8"
    setup_table(tbl)
    let c = connect(test_conninfo)
    let name_cn = "你好世界"
    c.execute("INSERT INTO \{tbl} (num, name, flag) VALUES ($1, $2, $3)", params=[
      1, name_cn, true,
    ])
    |> ignore
    let rows = c.query("SELECT name FROM \{tbl}")
    assert_true(rows.has_next())
    let row = rows.get_row()
    let n : String = row.get(0)
    assert_eq(n, name_cn)
    rows.close()
    c.close()
  })
}

///|
async test "query_syntax_error_raises" {
  log_err("query_syntax_error_raises", async fn() {
    let c = connect(test_conninfo)
    try {
      let _ = c.query("SELEC 1")
      fail("expected syntax error")
    } catch {
      _ => ()
    }
    c.close()
  })
}

// ---------------------------------------------------------------------------
// Concurrency: slow query on one connection does not block fast queries
// on other connections.  In an async model the two SELECT 1 calls should
// return almost instantly while SELECT pg_sleep(2) is still pending.
// ---------------------------------------------------------------------------

///|
async test "async_concurrent_queries_dont_block" {
  log_err("async_concurrent_queries_dont_block", async fn() {
    let c1 = connect(test_conninfo)
    let c2 = connect(test_conninfo)
    let c3 = connect(test_conninfo)
    let wall = @async.now()
    let fast1_done : Ref[Int64] = Ref(0L)
    let fast2_done : Ref[Int64] = Ref(0L)
    let slow_done : Ref[Int64] = Ref(0L)

    @async.all([
      // Slow query: pg_sleep(2) blocks this connection for ~2 s
      async fn() {
        let rows = c1.query("SELECT pg_sleep(2)")
        rows.close()
        slow_done.val = @async.now() - wall
      },
      // Fast query 1: SELECT 1 — should return immediately
      async fn() {
        let rows = c2.query("SELECT 1")
        rows.close()
        fast1_done.val = @async.now() - wall
      },
      // Fast query 2: SELECT 1 — should return immediately
      async fn() {
        let rows = c3.query("SELECT 1")
        rows.close()
        fast2_done.val = @async.now() - wall
      },
    ])
    |> ignore

    let total = @async.now() - wall

    println(
      "concurrent: fast1=\{fast1_done.val}ms fast2=\{fast2_done.val}ms slow=\{slow_done.val}ms total=\{total}ms",
    )

    // Slow query should take at least ~1.5 s (pg_sleep(2) + overhead)
    assert_true(
      slow_done.val >= 1500L,
      msg="slow query took \{slow_done.val}ms, expected >= 1500ms",
    )

    // Fast queries should finish well before the slow one
    // (allow a few hundred ms for scheduling / network, but well under 1500ms)
    assert_true(
      fast1_done.val < 500L,
      msg="fast1 took \{fast1_done.val}ms, expected < 500ms",
    )
    assert_true(
      fast2_done.val < 500L,
      msg="fast2 took \{fast2_done.val}ms, expected < 500ms",
    )

    // Total wall time should be close to the slow query (~2 s), not 2+2+2 = 6 s
    assert_true(
      total < 3000L,
      msg="total wall time \{total}ms, expected < 3000ms (concurrent, not serial)",
    )

    c1.close()
    c2.close()
    c3.close()
  })
}
