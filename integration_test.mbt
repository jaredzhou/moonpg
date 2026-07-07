///|
// Integration tests against a live PostgreSQL instance.
//
// Connection string (override with env var MOONPG_CONNINFO if needed):
//   postgres://postgres:111111@localhost:5432/postgres
//
// Run with:
//   moon test --target native

///|
let conninfo : String = @env.get_env_var("MOONPG_CONNINFO").unwrap_or(
  "postgres://postgres:111111@localhost:5432/postgres",
)

///|
fn fresh_table() -> Unit raise PgError {
  let conn = connect(conninfo)
  defer conn.close()
  conn.execute("DROP TABLE IF EXISTS moonpg_types") |> ignore
  conn.execute(
    (
      #|CREATE TABLE moonpg_types (
      #|  id    SERIAL PRIMARY KEY,
      #|  i4    INTEGER       NOT NULL,
      #|  i8    BIGINT        NOT NULL,
      #|  f8    DOUBLE PRECISION NOT NULL,
      #|  flag  BOOLEAN       NOT NULL,
      #|  name  TEXT          NOT NULL,
      #|  email TEXT
      #|)
    ),
  )
  |> ignore
}

///|
test "execute_ddl_and_dml_with_params" {
  fresh_table()
  let conn = connect(conninfo)
  defer conn.close()

  // Insert with params — exercises `ToValue` for Int / Int64 / Double / Bool /
  // String / Option[T] end-to-end through PQexecParams.
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
  r1.free()

  // Verify the values round-tripped by reading them back through `FromValue`.
  let rows = conn.query("SELECT i4, i8, f8, flag, name, email FROM moonpg_types")
  defer rows.free()
  let iter = rows.iter()
  match iter.next() {
    Some(row) => {
      assert_eq(row.get_by_name("i4"), 42, msg="i4 round-trip")
      assert_eq(row.get_by_name("i8"), 9_000_000_000L, msg="i8 round-trip")
      assert_true(
        (row.get_by_name("f8") : Double) - 3.14 < 1.0e-9,
        msg="f8 round-trip close to 3.14",
      )
      assert_eq(row.get_by_name("flag"), true, msg="flag round-trip")
      assert_eq(row.get_by_name("name"), "alice", msg="name round-trip")
      let email : String? = row.get_by_name("email")
      assert_eq(email, Some("alice@example.com"), msg="email round-trip")
    }
    None => fail("expected the inserted row back")
  }

  // Update with a Bool param.
  let p_flag_false : Bool = false
  let r2 = conn.execute(
    "UPDATE moonpg_types SET flag = $1",
    params=[p_flag_false],
  )
  assert_eq(r2.affected_rows(), 1, msg="update affected_rows")
  r2.free()

  // Insert a second row with a NULL email — exercises `ToValue for Option[T]`
  // where `None` encodes as `Value::Null`.
  let p_email_none : String? = None
  let r2b = conn.execute(
    (
      #|INSERT INTO moonpg_types (i4, i8, f8, flag, name, email)
      #|VALUES (1, 1, 1.0, true, 'no-email', $1)
    ),
    params=[p_email_none],
  )
  assert_eq(r2b.affected_rows(), 1, msg="insert with NULL email")
  r2b.free()

  // Delete with a String param.
  let p_who : String = "alice"
  let r3 = conn.execute(
    "DELETE FROM moonpg_types WHERE name = $1",
    params=[p_who],
  )
  assert_eq(r3.affected_rows(), 1, msg="delete affected_rows")
  r3.free()
}

///|
test "query_iterates_all_basic_types" {
  fresh_table()
  let conn = connect(conninfo)
  defer conn.close()

  conn.execute(
    "INSERT INTO moonpg_types (i4, i8, f8, flag, name, email) VALUES (7, 1234567890123, 2.71828, true, 'bob', NULL)",
  )
  |> ignore

  let rows = conn.query(
    "SELECT id, i4, i8, f8, flag, name, email FROM moonpg_types",
  )
  defer rows.free()

  let collected : Array[(Int, Int, Int64, Double, Bool, String, String?)] = []
  for row in rows.iter() {
    let id : Int = row.get(0)
    let i4 : Int = row.get(1)
    let i8 : Int64 = row.get(2)
    let f8 : Double = row.get(3)
    let flag : Bool = row.get(4)
    let name : String = row.get(5)
    let email : String? = row.get(6)
    collected.push((id, i4, i8, f8, flag, name, email))
  }

  assert_eq(collected.length(), 1, msg="row count")
  let entry = collected[0]
  let id = entry.0
  let i4 = entry.1
  let i8 = entry.2
  let f8 = entry.3
  let flag = entry.4
  let name = entry.5
  let email = entry.6
  assert_eq(i4, 7, msg="i4")
  assert_eq(i8, 1234567890123L, msg="i8")
  assert_true((f8 - 2.71828).abs() < 1.0e-9, msg="f8 close to 2.71828")
  assert_eq(flag, true, msg="flag")
  assert_eq(name, "bob", msg="name")
  assert_eq(email, None, msg="email is NULL")
  assert_true(id > 0, msg="id > 0")
}

///|
test "get_by_name" {
  fresh_table()
  let conn = connect(conninfo)
  defer conn.close()

  conn.execute(
    "INSERT INTO moonpg_types (i4, i8, f8, flag, name, email) VALUES (-1, -9223372036854775808, -0.5, false, 'carol', 'c@x.io')",
  )
  |> ignore

  let rows = conn.query(
    "SELECT i4, i8, f8, flag, name, email FROM moonpg_types",
  )
  defer rows.free()

  let iter = rows.iter()
  match iter.next() {
    Some(row) => {
      assert_eq(row.get_by_name("i4"), -1, msg="i4 by name")
      assert_eq(row.get_by_name("i8"), -9223372036854775808L, msg="i8 by name")
      assert_eq(row.get_by_name("flag"), false, msg="flag by name")
      assert_eq(row.get_by_name("name"), "carol", msg="name by name")
      let email : String? = row.get_by_name("email")
      assert_eq(email, Some("c@x.io"), msg="email by name")
    }
    None => fail("expected exactly one row")
  }
}

///|
test "null_raises_for_basic_types" {
  fresh_table()
  let conn = connect(conninfo)
  defer conn.close()

  conn.execute(
    "INSERT INTO moonpg_types (i4, i8, f8, flag, name, email) VALUES (0, 0, 0.0, true, 'no-email', NULL)",
  )
  |> ignore

  let rows = conn.query("SELECT email FROM moonpg_types")
  defer rows.free()
  let iter = rows.iter()
  match iter.next() {
    Some(row) => {
      // Asking for `String` on a NULL column must raise.
      try (row.get(0):String) |> ignore catch {
        err => println("expected NULL to raise, got: \{err.to_repr()}")
      }
      // `Option[String]` should give None.
      let email : String? = row.get(0)
      assert_eq(email, None, msg="Option[String] on NULL")
    }
    None => fail("expected a row")
  }
}

///|
test "unknown_column_raises" {
  fresh_table()
  let conn = connect(conninfo)
  defer conn.close()
  conn.execute(
    "INSERT INTO moonpg_types (i4, i8, f8, flag, name, email) VALUES (1, 1, 1.0, true, 'd', NULL)",
  )
  |> ignore
  let rows = conn.query("SELECT i4 FROM moonpg_types")
  defer rows.free()
  let iter = rows.iter()
  match iter.next() {
    Some(row) => {
      let raised : Result[Int, PgError] = try? {
        let v : Int = row.get_by_name("nope")
        v
      }
      match raised {
        Err(_) => ()
        Ok(v) => fail("expected missing column to raise, got: \{v}")
      }
    }
    None => fail("expected a row")
  }
}

///|
test "iter_collects_multiple_rows" {
  fresh_table()
  let conn = connect(conninfo)
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
  defer rows.free()
  let names : Array[String] = []
  for row in rows.iter() {
    let s : String = row.get_by_name("name")
    names.push(s)
  }
  assert_eq(names, ["one", "two", "three"])
}

///|
test "query_one_returns_single_row" {
  fresh_table()
  let conn = connect(conninfo)
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
test "query_one_raises_when_no_match" {
  fresh_table()
  let conn = connect(conninfo)
  defer conn.close()
  // No INSERTs — table is empty after fresh_table().
  let raised : Result[Unit, PgError] = try? {
    let _ = conn.query_one(
      "SELECT i4 FROM moonpg_types WHERE name = $1",
      params=["ghost"],
    )
    ()
  }
  match raised {
    Err(e) =>
      assert_true(
        e.to_repr().to_string().contains("no rows"),
        msg="error repr, got: \{e.to_repr()}",
      )
    Ok(_) => fail("expected query_one on empty table to raise")
  }
}

///|
test "query_one_returns_first_when_multiple_match" {
  fresh_table()
  let conn = connect(conninfo)
  defer conn.close()

  conn.execute(
    "INSERT INTO moonpg_types (i4, i8, f8, flag, name, email) VALUES (1, 1, 1.0, true, 'first', NULL)",
  )
  |> ignore
  conn.execute(
    "INSERT INTO moonpg_types (i4, i8, f8, flag, name, email) VALUES (2, 2, 2.0, false, 'second', NULL)",
  )
  |> ignore

  let row = conn.query_one(
    "SELECT name FROM moonpg_types ORDER BY i4",
  )
  let name : String = row.get(0)
  assert_eq(name, "first", msg="query_one returns first row by ORDER BY")
}

///|
test "server_version_is_positive" {
  let conn = connect(conninfo)
  defer conn.close()
  let v = conn.server_version()
  assert_true(v > 0, msg="server_version > 0")
}

///|
/// Regression guard for non-ASCII text decoding. The previous byte-cast
/// path silently corrupted multi-byte UTF-8 (e.g. Chinese, accented Latin);
/// this test would have caught it.
test "text_round_trips_utf8" {
  fresh_table()
  let conn = connect(conninfo)
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
  r.free()

  let rows = conn.query("SELECT name, email FROM moonpg_types")
  defer rows.free()
  let iter = rows.iter()
  match iter.next() {
    Some(row) => {
      let name : String = row.get(0)
      let email : String? = row.get(1)
      assert_eq(name, "你好世界", msg="utf8 name round-trip")
      assert_eq(email, Some("café@exämple.日本"), msg="utf8 email round-trip")
    }
    None => fail("expected the inserted utf8 row back")
  }
}

///|
/// Regression guard for non-ASCII column names. `Rows::columns()` reads the
/// names through `moonpg_fname_bytes`, which now returns raw UTF-8 bytes
/// decoded on the MoonBit side; a byte-cast to UTF-16 would corrupt them.
test "column_names_round_trip_utf8" {
  let conn = connect(conninfo)
  defer conn.close()
  // Idempotent: drop in case a previous run left the table behind.
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
  defer rows.free()
  let cols = rows.columns()
  assert_eq(cols.length(), 2, msg="two columns")
  assert_eq(cols[0], "编号", msg="first column name is 中文")
  assert_eq(cols[1], "名前", msg="second column name is 日本語")

  conn.execute("DROP TABLE moonpg_utf8_cols") |> ignore
}

///|
/// Regression guard for non-ASCII error messages. Triggers a controllable
/// Chinese error via PL/pgSQL `RAISE EXCEPTION` and asserts the captured
/// error round-trips through `moonpg_error_message_bytes` and `@utf8.decode`
/// intact. `PgError` is an abstract suberror, so we use `to_repr()` to get
/// its debug rendering and check it contains the expected text.
test "error_message_round_trips_utf8" {
  let conn = connect(conninfo)
  defer conn.close()
  let raised : Result[Unit, PgError] = try? {
    let _ = conn.execute(
      (
        #|DO $$ BEGIN
        #|  RAISE EXCEPTION '中文错误信息: %', '详情';
        #|END $$
      ),
    )
    ()
  }
  match raised {
    Err(e) =>
      assert_true(
        e.to_repr().to_string().contains("中文错误信息"),
        msg="error repr contains 中文错误信息, got: \{e.to_repr()}",
      )
    Ok(_) => fail("expected RAISE EXCEPTION to raise")
  }
}