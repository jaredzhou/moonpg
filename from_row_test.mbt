///|
// Unit tests for FromRow, fetch, fetch_one, and tuple FromRow impls.
// Run with: moon test --target native

let fr_test_conninfo : String = @env.get_env_var("PGCONN").unwrap_or(
  "postgres://postgres:111111@localhost:5432/postgres",
)

///|
async fn fr_setup(name : String) -> Unit raise PgError {
  let c = connect(fr_test_conninfo)
  c.execute("DROP TABLE IF EXISTS \{name}") |> ignore
  c.execute(
    "CREATE TABLE \{name} (id SERIAL PRIMARY KEY, int_val INTEGER, big_val BIGINT, float_val DOUBLE PRECISION, bool_val BOOLEAN, text_val TEXT, bytea_val BYTEA, json_val JSONB, ts_val TIMESTAMPTZ, dec_val NUMERIC, uuid_val UUID)",
  )
  |> ignore
  c.close()
}

// ===========================================================================
// FromRow — built-in types (via Connection)
// ===========================================================================

///|
async test "from_row_int" {
  let tbl = "fr_int"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  c.execute("INSERT INTO \{tbl} (int_val) VALUES (42)") |> ignore
  let rows = c.query("SELECT int_val FROM \{tbl}")
  assert_true(rows.has_next())
  let row = rows.get_row()
  let v : Int = FromRow::from_row(row)
  assert_eq(v, 42)
  rows.close()
  c.close()
}

///|
async test "from_row_int64" {
  let tbl = "fr_i64"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  c.execute("INSERT INTO \{tbl} (big_val) VALUES (9223372036854775807)")
  |> ignore
  let rows = c.query("SELECT big_val FROM \{tbl}")
  assert_true(rows.has_next())
  let row = rows.get_row()
  let v : Int64 = FromRow::from_row(row)
  assert_eq(v, 9223372036854775807L)
  rows.close()
  c.close()
}

///|
async test "from_row_double" {
  let tbl = "fr_dbl"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  c.execute("INSERT INTO \{tbl} (float_val) VALUES (3.14)") |> ignore
  let rows = c.query("SELECT float_val FROM \{tbl}")
  assert_true(rows.has_next())
  let row = rows.get_row()
  let v : Double = FromRow::from_row(row)
  // floating point roundtrip check
  let diff = v - 3.14
  assert_true(if diff < 0.0 { -diff < 0.001 } else { diff < 0.001 })
  rows.close()
  c.close()
}

///|
async test "from_row_bool" {
  let tbl = "fr_bool"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  c.execute("INSERT INTO \{tbl} (bool_val) VALUES ($1)", params=[true])
  |> ignore
  let rows = c.query("SELECT bool_val FROM \{tbl}")
  assert_true(rows.has_next())
  let row = rows.get_row()
  let v : Bool = FromRow::from_row(row)
  assert_eq(v, true)
  rows.close()
  c.close()
}

///|
async test "from_row_string" {
  let tbl = "fr_str"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  c.execute("INSERT INTO \{tbl} (text_val) VALUES ('hello_from_row')") |> ignore
  let rows = c.query("SELECT text_val FROM \{tbl}")
  assert_true(rows.has_next())
  let row = rows.get_row()
  let v : String = FromRow::from_row(row)
  assert_eq(v, "hello_from_row")
  rows.close()
  c.close()
}

///|
async test "from_row_bytes" {
  let tbl = "fr_bytes"
  let c = connect(fr_test_conninfo)
  c.execute("DROP TABLE IF EXISTS \{tbl}") |> ignore
  c.execute("CREATE TABLE \{tbl} (id SERIAL PRIMARY KEY, data BYTEA)") |> ignore
  let input = b"\xDE\xAD\xBE\xEF"
  c.execute("INSERT INTO \{tbl} (data) VALUES ($1)", params=[input]) |> ignore
  let rows = c.query("SELECT data FROM \{tbl}")
  assert_true(rows.has_next())
  let row = rows.get_row()
  let v : Bytes = FromRow::from_row(row)
  assert_eq(v, input)
  rows.close()
  c.close()
}

///|
async test "from_row_json" {
  let tbl = "fr_json"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  c.execute("INSERT INTO \{tbl} (json_val) VALUES ('{\"a\":1}')") |> ignore
  let rows = c.query("SELECT json_val FROM \{tbl}")
  assert_true(rows.has_next())
  let row = rows.get_row()
  let v : Json = FromRow::from_row(row)
  assert_eq(v.stringify(), "{\"a\":1}")
  rows.close()
  c.close()
}

///|
async test "from_row_timestamp" {
  let tbl = "fr_ts"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  c.execute("INSERT INTO \{tbl} (ts_val) VALUES ('2024-01-01 00:00:00Z')")
  |> ignore
  let rows = c.query("SELECT ts_val FROM \{tbl}")
  assert_true(rows.has_next())
  let row = rows.get_row()
  let v : Timestamp = FromRow::from_row(row)
  // 2024-01-01 00:00:00 UTC in microseconds
  assert_eq(v.0, 1704067200000000L)
  rows.close()
  c.close()
}

///|
async test "from_row_decimal" {
  let tbl = "fr_dec"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  c.execute("INSERT INTO \{tbl} (dec_val) VALUES ('3.14')") |> ignore
  let rows = c.query("SELECT dec_val FROM \{tbl}")
  assert_true(rows.has_next())
  let row = rows.get_row()
  let v : @decimal.Decimal = FromRow::from_row(row)
  assert_eq(v.to_string(), "3.14")
  rows.close()
  c.close()
}

///|
async test "from_row_uuid" {
  let tbl = "fr_uuid"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  c.execute(
    "INSERT INTO \{tbl} (uuid_val) VALUES ('550e8400-e29b-41d4-a716-446655440000')",
  )
  |> ignore
  let rows = c.query("SELECT uuid_val FROM \{tbl}")
  assert_true(rows.has_next())
  let row = rows.get_row()
  let v : @uuid.UUID = FromRow::from_row(row)
  assert_eq(v.to_string(), "550e8400-e29b-41d4-a716-446655440000")
  rows.close()
  c.close()
}

// ===========================================================================
// FromRow — Option<T> (nullable)
// ===========================================================================

///|
async test "from_row_option_some" {
  let tbl = "fr_opt_some"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  c.execute("INSERT INTO \{tbl} (int_val) VALUES (99)") |> ignore
  let rows = c.query("SELECT int_val FROM \{tbl}")
  assert_true(rows.has_next())
  let row = rows.get_row()
  let v : Int? = FromRow::from_row(row)
  match v {
    Some(n) => assert_eq(n, 99)
    None => fail("expected Some")
  }
  rows.close()
  c.close()
}

///|
async test "from_row_option_none" {
  let tbl = "fr_opt_none"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  c.execute("INSERT INTO \{tbl} (int_val) VALUES (NULL)") |> ignore
  let rows = c.query("SELECT int_val FROM \{tbl}")
  assert_true(rows.has_next())
  let row = rows.get_row()
  let v : Int? = FromRow::from_row(row)
  match v {
    Some(_) => fail("expected None")
    None => ()
  }
  rows.close()
  c.close()
}

// ===========================================================================
// FromRow — custom struct
// ===========================================================================

///|
pub(all) struct MyUser {
  id : Int
  name : String
}

///|
impl FromRow for MyUser with fn from_row(r : Row) -> MyUser raise PgError {
  MyUser::{ id: r.get(0), name: r.get(1) }
}

///|
async test "from_row_custom_struct" {
  let tbl = "fr_custom"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  c.execute("INSERT INTO \{tbl} (int_val, text_val) VALUES (1, 'alice')")
  |> ignore
  let rows = c.query("SELECT int_val, text_val FROM \{tbl}")
  assert_true(rows.has_next())
  let row = rows.get_row()
  let user : MyUser = FromRow::from_row(row)
  assert_eq(user.id, 1)
  assert_eq(user.name, "alice")
  rows.close()
  c.close()
}

// ===========================================================================
// fetch / fetch_one — Connection
// ===========================================================================

///|
async test "fetch_connection_int" {
  let tbl = "fr_fetch_int"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  c.execute("INSERT INTO \{tbl} (int_val) VALUES (1), (2), (3)") |> ignore
  let vals : Array[Int] = &QueryExecutor::fetch(
    c,
    "SELECT int_val FROM \{tbl} ORDER BY int_val",
  )
  assert_eq(vals.length(), 3)
  assert_eq(vals[0], 1)
  assert_eq(vals[1], 2)
  assert_eq(vals[2], 3)
  c.close()
}

///|
async test "fetch_connection_empty" {
  let tbl = "fr_fetch_empty"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  let vals : Array[Int] = &QueryExecutor::fetch(c, "SELECT int_val FROM \{tbl}")
  assert_eq(vals.length(), 0)
  c.close()
}

///|
async test "fetch_one_connection" {
  let tbl = "fr_f1"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  c.execute("INSERT INTO \{tbl} (int_val, text_val) VALUES (42, 'answer')")
  |> ignore
  let (n, s) : (Int, String) = &QueryExecutor::fetch_one(
    c,
    "SELECT int_val, text_val FROM \{tbl}",
  )
  assert_eq(n, 42)
  assert_eq(s, "answer")
  c.close()
}

///|
async test "fetch_one_connection_no_rows" {
  let tbl = "fr_f1_empty"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  try {
    let _ : Int = &QueryExecutor::fetch_one(c, "SELECT int_val FROM \{tbl}")
    fail("expected NoRows")
  } catch {
    e => assert_true(to_repr(e).to_string().contains("NoRows"))
  }
  c.close()
}

///|
async test "fetch_one_connection_nullable_some" {
  let tbl = "fr_f1_opt_some"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  c.execute("INSERT INTO \{tbl} (text_val) VALUES ('present')") |> ignore
  let val : String? = &QueryExecutor::fetch_one(
    c,
    "SELECT text_val FROM \{tbl}",
  )
  match val {
    Some(s) => assert_eq(s, "present")
    None => fail("expected Some")
  }
  c.close()
}

///|
async test "fetch_one_connection_nullable_none" {
  let tbl = "fr_f1_opt_none"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  c.execute("INSERT INTO \{tbl} (text_val) VALUES (NULL)") |> ignore
  let val : String? = &QueryExecutor::fetch_one(
    c,
    "SELECT text_val FROM \{tbl}",
  )
  match val {
    Some(_) => fail("expected None")
    None => ()
  }
  c.close()
}

// ===========================================================================
// fetch / fetch_one — Pool (auto-acquire + auto-release)
// ===========================================================================

///|
async test "fetch_pool" {
  let tbl = "fr_pool_fetch"
  fr_setup(tbl)
  let pool = Pool::new(PoolConfig::new(fr_test_conninfo, max_conns=2))
  pool.execute("INSERT INTO \{tbl} (int_val) VALUES (10), (20), (30)") |> ignore
  let vals : Array[Int] = &QueryExecutor::fetch(
    pool,
    "SELECT int_val FROM \{tbl} ORDER BY int_val",
  )
  assert_eq(vals.length(), 3)
  assert_eq(vals[0], 10)
  assert_eq(vals[1], 20)
  assert_eq(vals[2], 30)
  pool.close()
}

///|
async test "fetch_one_pool" {
  let tbl = "fr_pool_f1"
  fr_setup(tbl)
  let pool = Pool::new(PoolConfig::new(fr_test_conninfo, max_conns=2))
  pool.execute("INSERT INTO \{tbl} (int_val, text_val) VALUES (7, 'pool_f1')")
  |> ignore
  let (n, s) : (Int, String) = &QueryExecutor::fetch_one(
    pool,
    "SELECT int_val, text_val FROM \{tbl}",
  )
  assert_eq(n, 7)
  assert_eq(s, "pool_f1")
  pool.close()
}

///|
async test "fetch_pool_empty" {
  let tbl = "fr_pool_empty"
  fr_setup(tbl)
  let pool = Pool::new(PoolConfig::new(fr_test_conninfo, max_conns=2))
  let vals : Array[String] = &QueryExecutor::fetch(
    pool,
    "SELECT text_val FROM \{tbl}",
  )
  assert_eq(vals.length(), 0)
  pool.close()
}

// ===========================================================================
// fetch / fetch_one — PoolConn (explicit acquire)
// ===========================================================================

///|
async test "fetch_poolconn" {
  let tbl = "fr_pc_fetch"
  fr_setup(tbl)
  let pool = Pool::new(PoolConfig::new(fr_test_conninfo, max_conns=2))
  let pc = pool.acquire()
  pc.execute("INSERT INTO \{tbl} (text_val) VALUES ('a'), ('b')") |> ignore
  let vals : Array[String] = &QueryExecutor::fetch(
    pc,
    "SELECT text_val FROM \{tbl} ORDER BY text_val",
  )
  assert_eq(vals.length(), 2)
  assert_eq(vals[0], "a")
  assert_eq(vals[1], "b")
  pc.close()
  pool.close()
}

///|
async test "fetch_one_poolconn" {
  let tbl = "fr_pc_f1"
  fr_setup(tbl)
  let pool = Pool::new(PoolConfig::new(fr_test_conninfo, max_conns=2))
  let pc = pool.acquire()
  pc.execute("INSERT INTO \{tbl} (bool_val) VALUES (true)") |> ignore
  let v : Bool = &QueryExecutor::fetch_one(pc, "SELECT bool_val FROM \{tbl}")
  assert_eq(v, true)
  pc.close()
  pool.close()
}

// ===========================================================================
// fetch / fetch_one — PoolDbTx (transaction)
// ===========================================================================

///|
async test "fetch_pooldbtx" {
  let tbl = "fr_tx_fetch"
  fr_setup(tbl)
  let pool = Pool::new(PoolConfig::new(fr_test_conninfo, max_conns=2))
  let tx = pool.begin_tx()
  QueryExecutor::execute(tx, "INSERT INTO \{tbl} (int_val) VALUES ($1), ($2)", params=[
    1, 2,
  ])
  |> ignore
  let vals : Array[Int] = &QueryExecutor::fetch(
    tx,
    "SELECT int_val FROM \{tbl} ORDER BY int_val",
  )
  assert_eq(vals.length(), 2)
  assert_eq(vals[0], 1)
  assert_eq(vals[1], 2)
  Closer::close(tx)
  pool.close()
}

///|
async test "fetch_one_pooldbtx" {
  let tbl = "fr_tx_f1"
  fr_setup(tbl)
  let pool = Pool::new(PoolConfig::new(fr_test_conninfo, max_conns=2))
  let tx = pool.begin_tx()
  QueryExecutor::execute(tx, "INSERT INTO \{tbl} (int_val) VALUES ($1)", params=[
    99,
  ])
  |> ignore
  let v : Int = &QueryExecutor::fetch_one(tx, "SELECT int_val FROM \{tbl}")
  assert_eq(v, 99)
  Closer::close(tx)
  pool.close()
}

// ===========================================================================
// Tuple FromRow roundtrips
// ===========================================================================

///|
async test "tuple_2" {
  let tbl = "fr_tup2"
  fr_setup(tbl)
  let pool = Pool::new(PoolConfig::new(fr_test_conninfo, max_conns=2))
  pool.execute("INSERT INTO \{tbl} (int_val, text_val) VALUES ($1, $2)", params=[
    1, "one",
  ])
  |> ignore
  let rows : Array[(Int, String)] = &QueryExecutor::fetch(
    pool,
    "SELECT int_val, text_val FROM \{tbl}",
  )
  assert_eq(rows.length(), 1)
  let (a, b) = rows[0]
  assert_eq(a, 1)
  assert_eq(b, "one")
  pool.close()
}

///|
async test "tuple_3" {
  let tbl = "fr_tup3"
  fr_setup(tbl)
  let pool = Pool::new(PoolConfig::new(fr_test_conninfo, max_conns=2))
  pool.execute(
    "INSERT INTO \{tbl} (int_val, text_val, bool_val) VALUES ($1, $2, $3)",
    params=[2, "two", true],
  )
  |> ignore
  let (a, b, c) : (Int, String, Bool) = &QueryExecutor::fetch_one(
    pool,
    "SELECT int_val, text_val, bool_val FROM \{tbl}",
  )
  assert_eq(a, 2)
  assert_eq(b, "two")
  assert_eq(c, true)
  pool.close()
}

///|
async test "tuple_4" {
  let tbl = "fr_tup4"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  c.execute(
    "INSERT INTO \{tbl} (int_val, big_val, float_val, bool_val) VALUES ($1, $2, $3, $4)",
    params=[3, 300L, 2.718, false],
  )
  |> ignore
  let (a, b, d, e) : (Int, Int64, Double, Bool) = &QueryExecutor::fetch_one(
    c,
    "SELECT int_val, big_val, float_val, bool_val FROM \{tbl}",
  )
  assert_eq(a, 3)
  assert_eq(b, 300L)
  let diff = d - 2.718
  assert_true(if diff < 0.0 { -diff < 0.001 } else { diff < 0.001 })
  assert_eq(e, false)
  c.close()
}

///|
async test "tuple_5" {
  let tbl = "fr_tup5"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  c.execute(
    "INSERT INTO \{tbl} (int_val, big_val, float_val, bool_val, text_val) VALUES ($1, $2, $3, $4, $5)",
    params=[5, 500L, 1.1, true, "five"],
  )
  |> ignore
  let (a, b, d, e, f) : (Int, Int64, Double, Bool, String) = &QueryExecutor::fetch_one(
    c,
    "SELECT int_val, big_val, float_val, bool_val, text_val FROM \{tbl}",
  )
  assert_eq(a, 5)
  assert_eq(b, 500L)
  let diff = d - 1.1
  assert_true(if diff < 0.0 { -diff < 0.001 } else { diff < 0.001 })
  assert_eq(e, true)
  assert_eq(f, "five")
  c.close()
}

///|
async test "tuple_10" {
  let tbl = "fr_tup10"
  let c = connect(fr_test_conninfo)
  c.execute("DROP TABLE IF EXISTS \{tbl}") |> ignore
  c.execute(
    "CREATE TABLE \{tbl} (c0 INT, c1 INT, c2 INT, c3 INT, c4 INT, c5 INT, c6 INT, c7 INT, c8 INT, c9 INT)",
  )
  |> ignore
  c.execute("INSERT INTO \{tbl} VALUES (0, 1, 2, 3, 4, 5, 6, 7, 8, 9)")
  |> ignore
  let (a0, _a1, _a2, _a3, _a4, a5, _a6, _a7, _a8, a9) : (
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
    Int,
  ) = &QueryExecutor::fetch_one(
    c,
    "SELECT c0, c1, c2, c3, c4, c5, c6, c7, c8, c9 FROM \{tbl}",
  )
  assert_eq(a0, 0)
  assert_eq(a5, 5)
  assert_eq(a9, 9)
  c.close()
}

// ===========================================================================
// Error cases — fetch with type mismatch
// ===========================================================================

///|
async test "fetch_from_row_type_mismatch" {
  let tbl = "fr_type_err"
  fr_setup(tbl)
  let c = connect(fr_test_conninfo)
  c.execute("INSERT INTO \{tbl} (text_val) VALUES ('not_an_int')") |> ignore
  try {
    let _ : Array[Int] = &QueryExecutor::fetch(c, "SELECT text_val FROM \{tbl}")
    fail("expected type mismatch error")
  } catch {
    _ => ()
  }
  c.close()
}

// ===========================================================================
// Pool: fetch releases connection on error
// ===========================================================================

///|
async test "fetch_pool_releases_on_error" {
  let tbl = "fr_pool_err"
  fr_setup(tbl)
  let pool = Pool::new(PoolConfig::new(fr_test_conninfo, max_conns=2))
  pool.execute("INSERT INTO \{tbl} (text_val) VALUES ('x')") |> ignore
  let initial = pool.total()
  try {
    let _ : Array[Int] = &QueryExecutor::fetch(
      pool,
      "SELECT text_val FROM \{tbl}",
    )
    fail("expected error")
  } catch {
    _ => ()
  }
  // Pool connection should be released even after error
  assert_eq(pool.total(), initial)
  pool.close()
}
