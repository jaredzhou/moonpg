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
test "rows_helper_returns_text_grid" {
  fresh_table()
  let conn = connect(conninfo)
  defer conn.close()

  conn.execute(
    "INSERT INTO moonpg_types (i4, i8, f8, flag, name, email) VALUES (10, 10, 10.0, true, 'eve', NULL)",
  )
  |> ignore

  let result = conn.query("SELECT i4, name FROM moonpg_types")
  defer result.free()
  let grid = result.rows()
  assert_eq(grid.length(), 1, msg="one row")
  assert_eq(grid[0][0], "10", msg="i4 as text")
  assert_eq(grid[0][1], "eve", msg="name as text")
}

///|
test "server_version_is_positive" {
  let conn = connect(conninfo)
  defer conn.close()
  let v = conn.server_version()
  assert_true(v > 0, msg="server_version > 0")
}