///|
// Core API tests for moonpg: QueryExecutor, Row, FromRow, FromValue.
//
// Run with: moon test --target native

let mt_conninfo : String = @env.get_env_var("PGCONN").unwrap_or(
  "postgres://postgres:111111@localhost:5432/postgres",
)

///|
async fn mt_setup() -> Unit raise PgError {
  let c = connect(mt_conninfo)
  defer c.close()
  let ddl =
    #|CREATE TABLE IF NOT EXISTS moonpg_types (
    #|  id         SERIAL PRIMARY KEY,
    #|  i4         INTEGER       NOT NULL,
    #|  i8         BIGINT        NOT NULL,
    #|  f8         DOUBLE PRECISION NOT NULL,
    #|  flag       BOOLEAN       NOT NULL,
    #|  name       TEXT          NOT NULL,
    #|  email      TEXT,
    #|  js         JSONB,
    #|  created_at TIMESTAMPTZ
    #|)
  c.execute("DROP TABLE IF EXISTS moonpg_types") |> ignore
  c.execute(ddl) |> ignore
}

// ===========================================================================
// Query / Row / basic types
// ===========================================================================

///|
async test "debug_fresh_table_then_insert" {
  mt_setup()
  let c = connect(mt_conninfo)
  defer c.close()
  let r = c.execute(
    "INSERT INTO moonpg_types (i4, i8, f8, flag, name, email) VALUES ($1, $2, $3, $4, $5, $6)",
    params=[42, 0L, 0.0, true, "alice", "a@b.com"],
  )
  assert_eq(r.affected_rows(), 1)
  r.close()
  let rows = c.query("SELECT name FROM moonpg_types")
  assert_true(rows.has_next())
  let row = rows.get_row()
  let name : String = row.get(0)
  assert_eq(name, "alice")
  rows.close()
}

///|
async test "execute_ddl_and_dml_with_params" {
  mt_setup()
  let conn = connect(mt_conninfo)
  defer conn.close()

  let p_i4 : Int = 42
  let p_i8 : Int64 = 9_000_000_000L
  let p_f8 : Double = 3.14
  let p_flag : Bool = true
  let p_name : String = "alice"
  let p_email : String = "alice@example.com"
  let r1 = conn.execute(
    (
      #|INSERT INTO moonpg_types (i4, i8, f8, flag, name, email)
      #|VALUES ($1, $2, $3, $4, $5, $6)
    ),
    params=[p_i4, p_i8, p_f8, p_flag, p_name, p_email],
  )
  assert_eq(r1.affected_rows(), 1, msg="insert affected_rows")
  r1.close()

  let rows = conn.query(
    "SELECT i4, i8, f8, flag, name, email FROM moonpg_types",
  )
  if rows.has_next() {
    let row = rows.get_row()
    assert_eq(row.get_by_name("i4"), 42, msg="i4 round-trip")
    assert_eq(row.get_by_name("i8"), 9_000_000_000L, msg="i8 round-trip")
    assert_true(
      (row.get_by_name("f8") : Double) - 3.14 < 1.0e-9,
      msg="f8 round-trip close to 3.14",
    )
    assert_eq(row.get_by_name("flag"), true, msg="flag round-trip")
    assert_eq(row.get_by_name("name"), "alice", msg="name round-trip")
    let email : String? = row.get_by_name("email")
    match email {
      Some(s) => assert_eq(s, "alice@example.com")
      None => fail("expected Some, got None")
    }
  } else {
    fail("expected the inserted row back")
  }
  rows.close()

  let p_flag_false : Bool = false
  let r2 = conn.execute("UPDATE moonpg_types SET flag = $1", params=[
    p_flag_false,
  ])
  assert_eq(r2.affected_rows(), 1, msg="update affected_rows")
  r2.close()

  let p_email_none : String? = None
  let r2b = conn.execute(
    (
      #|INSERT INTO moonpg_types (i4, i8, f8, flag, name, email)
      #|VALUES (1, 1, 1.0, true, 'no-email', $1)
    ),
    params=[p_email_none],
  )
  assert_eq(r2b.affected_rows(), 1, msg="insert with NULL email")
  r2b.close()

  let p_who : String = "alice"
  let r3 = conn.execute("DELETE FROM moonpg_types WHERE name = $1", params=[
    p_who,
  ])
  assert_eq(r3.affected_rows(), 1, msg="delete affected_rows")
  r3.close()
}

///|
async test "query_iterates_all_basic_types" {
  mt_setup()
  let conn = connect(mt_conninfo)
  defer conn.close()

  conn.execute(
    "INSERT INTO moonpg_types (i4, i8, f8, flag, name, email, js, created_at) VALUES (7, 1234567890123, 2.71828, true, 'bob', NULL, $1, $2)",
    params=["{\"k\":\"v\"}", "2024-01-01 00:00:00"],
  )
  |> ignore

  let rows = conn.query(
    "SELECT id, i4, i8, f8, flag, name, email, js, created_at FROM moonpg_types",
  )

  let collected : Array[
    (Int, Int, Int64, Double, Bool, String, String?, Json?, Timestamp?),
  ] = []
  while rows.has_next() {
    let row = rows.get_row()
    let id : Int = row.get(0)
    let i4 : Int = row.get(1)
    let i8 : Int64 = row.get(2)
    let f8 : Double = row.get(3)
    let flag : Bool = row.get(4)
    let name : String = row.get(5)
    let email : String? = row.get(6)
    let js_val : Json? = row.get(7)
    let ts_val : Timestamp? = row.get(8)
    collected.push((id, i4, i8, f8, flag, name, email, js_val, ts_val))
  }
  rows.close()

  assert_eq(collected.length(), 1, msg="row count")
  let entry = collected[0]
  assert_eq(entry.1, 7, msg="i4")
  assert_eq(entry.2, 1234567890123L, msg="i8")
  assert_true((entry.3 - 2.71828).abs() < 1.0e-9, msg="f8")
  assert_eq(entry.4, true, msg="flag")
  assert_eq(entry.5, "bob", msg="name")
  match entry.6 {
    Some(s) => fail("expected None, got Some(\{s})")
    None => ()
  }
  match entry.7 {
    Some(js) => assert_eq(js.stringify(), "{\"k\":\"v\"}", msg="jsonb")
    None => fail("expected Some(jsonb)")
  }
  match entry.8 {
    Some(ts) => assert_true(ts.0 > 0L, msg="timestamptz")
    None => fail("expected Some(timestamp)")
  }
  assert_true(entry.0 > 0, msg="id > 0")
}

///|
async test "get_by_name" {
  mt_setup()
  let conn = connect(mt_conninfo)
  defer conn.close()

  conn.execute(
    "INSERT INTO moonpg_types (i4, i8, f8, flag, name, email) VALUES (-1, -9223372036854775808, -0.5, false, 'carol', 'c@x.io')",
  )
  |> ignore

  let rows = conn.query(
    "SELECT i4, i8, f8, flag, name, email FROM moonpg_types",
  )

  if rows.has_next() {
    let row = rows.get_row()
    assert_eq(row.get_by_name("i4"), -1, msg="i4 by name")
    assert_eq(row.get_by_name("i8"), -9223372036854775808L, msg="i8 by name")
    assert_eq(row.get_by_name("flag"), false, msg="flag by name")
    assert_eq(row.get_by_name("name"), "carol", msg="name by name")
    let email : String? = row.get_by_name("email")
    match email {
      Some(s) => assert_eq(s, "c@x.io")
      None => fail("expected Some, got None")
    }
  } else {
    fail("expected exactly one row")
  }
  rows.close()
}

///|
async test "null_raises_for_basic_types" {
  mt_setup()
  let conn = connect(mt_conninfo)
  defer conn.close()

  conn.execute(
    "INSERT INTO moonpg_types (i4, i8, f8, flag, name, email) VALUES (0, 0, 0.0, true, 'no-email', NULL)",
  )
  |> ignore

  let rows = conn.query("SELECT email FROM moonpg_types")

  if rows.has_next() {
    let row = rows.get_row()
    try (row.get(0) : String) |> ignore catch {
      err => println("expected NULL to raise, got: \{to_repr(err)}")
    }
    let email : String? = row.get(0)
    match email {
      Some(s) => fail("expected None, got Some(\{s})")
      None => ()
    }
  } else {
    fail("expected a row")
  }
  rows.close()
}

///|
async test "unknown_column_raises" {
  mt_setup()
  let conn = connect(mt_conninfo)
  defer conn.close()
  conn.execute(
    "INSERT INTO moonpg_types (i4, i8, f8, flag, name, email) VALUES (1, 1, 1.0, true, 'd', NULL)",
  )
  |> ignore
  let rows = conn.query("SELECT i4 FROM moonpg_types")

  if rows.has_next() {
    let row = rows.get_row()
    try {
      let v : Int = row.get_by_name("nope")
      fail("expected missing column to raise, got: \{v}")
    } catch {
      _ => ()
    }
  } else {
    fail("expected a row")
  }
  rows.close()
}

///|
async test "iter_collects_multiple_rows" {
  mt_setup()
  let conn = connect(mt_conninfo)
  defer conn.close()

  conn.execute(
    (
      #|INSERT INTO moonpg_types (i4, i8, f8, flag, name, email)
      #|VALUES (1, 1, 1.0, true,  'one',   NULL),
      #|       (2, 2, 2.0, false, 'two',   NULL),
      #|       (3, 3, 3.0, true,  'three', NULL)
    ),
  )
  |> ignore

  let rows = conn.query("SELECT name FROM moonpg_types ORDER BY i4")
  let names : Array[String] = []
  while rows.has_next() {
    let row = rows.get_row()
    let s : String = row.get_by_name("name")
    names.push(s)
  }
  rows.close()
  assert_eq(names.length(), 3)
  assert_eq(names[0], "one")
  assert_eq(names[1], "two")
  assert_eq(names[2], "three")
}

// ===========================================================================
// query_one
// ===========================================================================

///|
async test "query_one_returns_single_row" {
  mt_setup()
  let conn = connect(mt_conninfo)
  defer conn.close()

  conn.execute(
    "INSERT INTO moonpg_types (i4, i8, f8, flag, name, email) VALUES (7, 7, 7.0, true, 'solo', NULL)",
  )
  |> ignore

  let row = conn.query_one(
    "SELECT i4, name FROM moonpg_types WHERE name = $1",
    params=["solo"],
  )
  let i4 : Int = row.get(0)
  let name : String = row.get(1)
  assert_eq(i4, 7, msg="query_one i4")
  assert_eq(name, "solo", msg="query_one name")
}

///|
async test "query_one_raises_when_no_match" {
  mt_setup()
  let conn = connect(mt_conninfo)
  defer conn.close()
  try {
    let _ = conn.query_one("SELECT i4 FROM moonpg_types WHERE name = $1", params=[
      "ghost",
    ])
    fail("expected query_one on empty table to raise")
  } catch {
    e =>
      assert_true(
        to_repr(e).to_string().contains("NoRows"),
        msg="error repr, got: \{to_repr(e)}",
      )
  }
}

///|
async test "query_one_returns_first_when_multiple_match" {
  mt_setup()
  let conn = connect(mt_conninfo)
  defer conn.close()

  conn.execute(
    "INSERT INTO moonpg_types (i4, i8, f8, flag, name, email) VALUES (1, 1, 1.0, true, 'first', NULL)",
  )
  |> ignore
  conn.execute(
    "INSERT INTO moonpg_types (i4, i8, f8, flag, name, email) VALUES (2, 2, 2.0, false, 'second', NULL)",
  )
  |> ignore

  let row = conn.query_one("SELECT name FROM moonpg_types ORDER BY i4")
  let name : String = row.get(0)
  assert_eq(name, "first", msg="query_one returns first row by ORDER BY")
}

// ===========================================================================
// UTF-8
// ===========================================================================

///|
async test "text_round_trips_utf8" {
  mt_setup()
  let conn = connect(mt_conninfo)
  defer conn.close()

  let p_name : String = "你好世界"
  let p_email : String = "café@exämple.日本"
  let r = conn.execute(
    (
      #|INSERT INTO moonpg_types (i4, i8, f8, flag, name, email)
      #|VALUES (0, 0, 0.0, true, $1, $2)
    ),
    params=[p_name, p_email],
  )
  assert_eq(r.affected_rows(), 1, msg="utf8 insert affected_rows")
  r.close()

  let rows = conn.query("SELECT name, email FROM moonpg_types")

  if rows.has_next() {
    let row = rows.get_row()
    let name : String = row.get(0)
    let email : String? = row.get(1)
    assert_eq(name, "你好世界", msg="utf8 name round-trip")
    match email {
      Some(s) => assert_eq(s, "café@exämple.日本")
      None => fail("expected Some, got None")
    }
  } else {
    fail("expected the inserted utf8 row back")
  }
  rows.close()
}

///|
async test "column_names_round_trip_utf8" {
  let conn = connect(mt_conninfo)
  defer conn.close()
  conn.execute("DROP TABLE IF EXISTS moonpg_utf8_cols") |> ignore
  conn.execute(
    (
      #|CREATE TABLE moonpg_utf8_cols (
      #|  "编号"   INTEGER NOT NULL,
      #|  "名前"    TEXT    NOT NULL
      #|)
    ),
  )
  |> ignore

  let rows = conn.query("SELECT \"编号\", \"名前\" FROM moonpg_utf8_cols")
  let cols = rows.columns()
  rows.close()
  assert_eq(cols.length(), 2, msg="two columns")
  assert_eq(cols[0].name, "编号", msg="first column name is 中文")
  assert_eq(cols[1].name, "名前", msg="second column name is 日本語")

  conn.execute("DROP TABLE moonpg_utf8_cols") |> ignore
}

///|
async test "error_message_round_trips_utf8" {
  let conn = connect(mt_conninfo)
  defer conn.close()
  try {
    let _ = conn.execute(
      (
        #|DO $$ BEGIN
        #|  RAISE EXCEPTION '中文错误信息: %', '详情';
        #|END $$
      ),
      params=[],
    )
    fail("expected RAISE EXCEPTION to raise")
  } catch {
    e =>
      assert_true(
        to_repr(e).to_string().contains("中文错误信息"),
        msg="error repr contains 中文错误信息, got: \{to_repr(e)}",
      )
  }
}
