///|
async test "connect_plain" {
  connect("postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test").close()
}

///|
async test "connect_md5" {
  connect("postgres://moonpg_md5:md5_pass@localhost:5432/moonpg_test").close()
}

///|
async test "connect_scram" {
  try {
    let conn = connect(
      "postgres://moonpg_scram:scram_pass@localhost:5432/moonpg_test",
    )
    conn.close()
  } catch {
    WireError::InvalidMessage(m) => fail("SCRAM InvalidMessage: \{m}")
    WireError::Auth(m) => fail("SCRAM Auth: \{m}")
    WireError::Connect(m) => fail("SCRAM Connect: \{m}")
    _ => fail("SCRAM other error")
  }
}

///|
async test "connect_ssl_prefer" {
  // sslmode=prefer against non-TLS server should gracefully fall back to plain.
  connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test?sslmode=prefer",
  ).close()
}

///|
async test "connect_ssl_require_non_tls_server" {
  // sslmode=require against non-TLS server should raise.
  try {
    connect(
      "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test?sslmode=require",
    ).close()
    fail("expected sslmode=require to raise")
  } catch {
    WireError::Connect(_) => ()
    e => fail("expected WireError::Connect, got: \{to_repr(e)}")
  }
}

///|
async test "kv" {
  connect(
    "host=localhost port=5432 user=moonpg_plain dbname=moonpg_test password=plain_pass",
  ).close()
}

///|
async test "server_params" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  assert_true(conn.param("server_version") is Some(_))

  assert_true(conn.param("server_encoding") is Some(_))
  assert_true(conn.param("client_encoding") is Some(_))
}

///|
async test "reconnect" {
  for i = 0; i < 3; i = i + 1 {
    connect("postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test").close()
  }
}

// ---------------------------------------------------------------------------
// Simple query tests
// ---------------------------------------------------------------------------

///|
async test "simple_select_pull" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let r = conn.simple_query("SELECT 1 AS n")
  assert_eq(r.columns().length(), 1)
  assert_eq(r.columns()[0].name, "n")
  assert_true(r.has_next())
  let row = r.data_row()
  assert_true(row is [Some(bs)] && @utf8.decode(bs) == "1")
  assert_false(r.has_next())
  let tag = r.close()
  assert_eq(tag.command(), "SELECT")
  assert_true(tag.rows_affected() is Some(1))
}

///|
async test "simple_select_batch" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let result = conn.simple_query("SELECT generate_series(1, 3) AS x").read()
  assert_eq(result.columns.length(), 1)
  assert_true(
    result.rows is [r1, r2, r3] &&
    r1 is [Some(bs1)] &&
    r2 is [Some(bs2)] &&
    r3 is [Some(bs3)] &&
    @utf8.decode(bs1) == "1" &&
    @utf8.decode(bs2) == "2" &&
    @utf8.decode(bs3) == "3",
  )
  assert_eq(result.tag.command(), "SELECT")
}

///|
async test "simple_insert" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  // Create temp table
  let _ = conn
    .simple_query(
      "CREATE TEMP TABLE _sq_test (id serial primary key, name text)",
    )
    .close()
  let r = conn.simple_query(
    "INSERT INTO _sq_test (name) VALUES ('alice'), ('bob')",
  )
  assert_eq(r.columns().length(), 0)
  let tag = r.close()
  assert_eq(tag.command(), "INSERT")
  assert_true(tag.rows_affected() is Some(2))
}

///|
async test "simple_update" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let _ = conn.simple_query("CREATE TEMP TABLE _sq_upd (x int)").close()
  let _ = conn.simple_query("INSERT INTO _sq_upd VALUES (1), (2), (3)").close()
  let tag = conn.simple_query("UPDATE _sq_upd SET x = 10 WHERE x > 1").close()
  assert_eq(tag.command(), "UPDATE")
  assert_true(tag.rows_affected() is Some(2))
}

///|
async test "simple_empty_query" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let tag = conn.simple_query("").close()
  assert_eq(tag.command(), "")
}

///|
async test "simple_multi_statement_rejected" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  (conn.simple_query("SELECT 1; SELECT 2").close() |> ignore) catch {
    WireError::Parse(s) =>
      inspect(
        s,
        content=(
          #|simple_query: multiple statements not supported — use extended query for multi-statement batches
        ),
      )
    _ => fail("unexpected error type")
  }
}

///|
async test "simple_trailing_semicolon" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let tag = conn.simple_query("SELECT 1;").close()
  assert_eq(tag.command(), "SELECT")
}

///|
async test "simple_syntax_error" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  (conn.simple_query("SELEC 1").read() |> ignore) catch {
    WireError::PgServer(s) =>
      inspect(
        s,
        content=(
          #|syntax error at or near "SELEC"
        ),
      )
    _ => fail("unexpected error type")
  }
}

///|
async test "simple_close_before_exhaust" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let r = conn.simple_query("SELECT generate_series(1, 10) AS x")
  // Read only 2 rows, then close.
  assert_true(r.has_next())
  let _ = r.data_row()
  assert_true(r.has_next())
  let _ = r.data_row()
  let tag = r.close()
  assert_eq(tag.command(), "SELECT")
}

///|
async test "simple_double_close" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let r = conn.simple_query("SELECT 1")
  let tag1 = r.close()
  let tag2 = r.close()
  assert_eq(tag1.command(), tag2.command())
}

///|
async test "simple_no_rows" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let _ = conn.simple_query("CREATE TEMP TABLE _sq_empty (x int)").close()
  let r = conn.simple_query("SELECT * FROM _sq_empty WHERE false")
  assert_eq(r.columns().length(), 1)
  assert_false(r.has_next())
  let tag = r.close()
  assert_true(tag.rows_affected() is Some(0))
}

///|
async test "simple_multiple_queries" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  // Several queries in sequence — each should work.
  let tag1 = conn.simple_query("SELECT 1").close()
  assert_eq(tag1.command(), "SELECT")
  let tag2 = conn.simple_query("SELECT 2").close()
  assert_eq(tag2.command(), "SELECT")
  let tag3 = conn.simple_query("SELECT 3").close()
  assert_eq(tag3.command(), "SELECT")
}

// ---------------------------------------------------------------------------
// Extended query — execute_params tests
// ---------------------------------------------------------------------------

///|
/// Shorthand to encode a UTF-8 string into bytes for text-format params.
fn enc(s : String) -> Bytes {
  @utf8.encode(s)
}

///|
async test "ext_select_params" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let reader = conn.execute_params(
    "SELECT $1::int + $2::int AS sum",
    [Some(enc("10")), Some(enc("32"))],
    [23, 23],
    [],
    [],
  )
  assert_eq(reader.columns().length(), 1)
  assert_eq(reader.columns()[0].name, "sum")
  assert_true(reader.has_next())
  let row = reader.data_row()
  assert_true(row is [Some(bs)] && @utf8.decode(bs) == "42")
  assert_false(reader.has_next())
  let tag = reader.close()
  assert_eq(tag.command(), "SELECT")
  assert_true(tag.rows_affected() is Some(1))
}

///|
async test "ext_select_text_params" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let reader = conn.execute_params(
    "SELECT $1 || $2 AS concat",
    [Some(enc("hello, ")), Some(enc("world"))],
    [],
    [],
    [],
  )
  assert_eq(reader.columns().length(), 1)
  assert_eq(reader.columns()[0].name, "concat")
  let result = reader.read()
  assert_eq(result.rows.length(), 1)
  match result.rows[0] {
    [Some(bs)] => assert_eq(@utf8.decode(bs), "hello, world")
    _ => fail("expected one text column")
  }
}

///|
async test "ext_select_null_param" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let reader = conn.execute_params(
    "SELECT $1::text IS NULL AS is_null",
    [None],
    [25],
    [],
    [],
  )
  assert_true(reader.has_next())
  let row = reader.data_row()
  assert_true(row is [Some(bs)] && @utf8.decode(bs) == "t")
  assert_false(reader.has_next())
  reader.close() |> ignore
}

///|
async test "ext_select_no_params" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let reader = conn.execute_params("SELECT 1 + 2 AS n", [], [], [], [])
  assert_eq(reader.columns().length(), 1)
  assert_eq(reader.columns()[0].name, "n")
  let result = reader.read()
  match result.rows[0] {
    [Some(bs)] => assert_eq(@utf8.decode(bs), "3")
    _ => fail("expected one column")
  }
}

///|
async test "ext_select_no_rows" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let _ = conn.simple_query("CREATE TEMP TABLE _ex_empty (x int)").close()
  let reader = conn.execute_params(
    "SELECT * FROM _ex_empty WHERE false",
    [],
    [],
    [],
    [],
  )
  assert_eq(reader.columns().length(), 1)
  assert_false(reader.has_next())
  let tag = reader.close()
  assert_eq(tag.command(), "SELECT")
  assert_true(tag.rows_affected() is Some(0))
}

///|
async test "ext_insert_params" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let _ = conn
    .simple_query(
      "CREATE TEMP TABLE _ex_ins (id serial primary key, name text)",
    )
    .close()
  let reader = conn.execute_params(
    "INSERT INTO _ex_ins (name) VALUES ($1)",
    [Some(enc("alice"))],
    [],
    [],
    [],
  )
  assert_eq(reader.columns().length(), 0)
  let tag = reader.close()
  assert_eq(tag.command(), "INSERT")
  assert_true(tag.rows_affected() is Some(1))
}

///|
async test "ext_insert_multi" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let _ = conn.simple_query("CREATE TEMP TABLE _ex_im (x int, y text)").close()
  let reader = conn.execute_params(
    "INSERT INTO _ex_im (x, y) VALUES ($1, $2), ($3, $4)",
    [Some(enc("1")), Some(enc("a")), Some(enc("2")), Some(enc("b"))],
    [],
    [],
    [],
  )
  let tag = reader.close()
  assert_eq(tag.command(), "INSERT")
  assert_true(tag.rows_affected() is Some(2))
}

///|
async test "ext_update_params" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let _ = conn.simple_query("CREATE TEMP TABLE _ex_upd (x int)").close()
  let _ = conn.simple_query("INSERT INTO _ex_upd VALUES (1), (2), (3)").close()
  let reader = conn.execute_params(
    "UPDATE _ex_upd SET x = x * 10 WHERE x > $1",
    [Some(enc("1"))],
    [],
    [],
    [],
  )
  let tag = reader.close()
  assert_eq(tag.command(), "UPDATE")
  assert_true(tag.rows_affected() is Some(2))
}

///|
async test "ext_delete_params" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let _ = conn.simple_query("CREATE TEMP TABLE _ex_del (x int)").close()
  let _ = conn.simple_query("INSERT INTO _ex_del VALUES (1), (2), (3)").close()
  let reader = conn.execute_params(
    "DELETE FROM _ex_del WHERE x = $1",
    [Some(enc("2"))],
    [],
    [],
    [],
  )
  let tag = reader.close()
  assert_eq(tag.command(), "DELETE")
  assert_true(tag.rows_affected() is Some(1))
}

///|
async test "ext_returning" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let _ = conn
    .simple_query("CREATE TEMP TABLE _ex_ret (id serial primary key, val text)")
    .close()
  let reader = conn.execute_params(
    "INSERT INTO _ex_ret (val) VALUES ($1) RETURNING id, val",
    [Some(enc("xyz"))],
    [],
    [],
    [],
  )
  assert_eq(reader.columns().length(), 2)
  assert_eq(reader.columns()[0].name, "id")
  assert_eq(reader.columns()[1].name, "val")
  assert_true(reader.has_next())
  let row = reader.data_row()
  assert_true(row is [Some(_), Some(v)] && @utf8.decode(v) == "xyz")
  let tag = reader.close()
  assert_eq(tag.command(), "INSERT")
}

///|
async test "ext_pull_iteration" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let reader = conn.execute_params(
    "SELECT generate_series($1::int, $2::int) AS x",
    [Some(enc("1")), Some(enc("5"))],
    [23, 23],
    [],
    [],
  )
  let values : Array[String] = []
  while reader.has_next() {
    let row = reader.data_row()
    match row {
      [Some(bs)] => values.push(@utf8.decode(bs))
      _ => fail("expected one column")
    }
  }
  let tag = reader.close()
  assert_true(values == ["1", "2", "3", "4", "5"])
  assert_eq(tag.command(), "SELECT")
}

///|
async test "ext_batch_read" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let result = conn
    .execute_params(
      "SELECT $1::int * i AS prod FROM generate_series(1, 3) AS i",
      [Some(enc("10"))],
      [23],
      [],
      [],
    )
    .read()
  assert_eq(result.columns[0].name, "prod")
  assert_eq(result.rows.length(), 3)
  match result.rows {
    [r1, r2, r3] =>
      assert_true(
        [
          @utf8.decode(r1[0].unwrap()),
          @utf8.decode(r2[0].unwrap()),
          @utf8.decode(r3[0].unwrap()),
        ] ==
        ["10", "20", "30"],
      )
    _ => fail("expected 3 rows")
  }
  assert_eq(result.tag.command(), "SELECT")
}

///|
async test "ext_close_before_exhaust" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let reader = conn.execute_params(
    "SELECT generate_series(1, 10) AS x",
    [],
    [],
    [],
    [],
  )
  // Read 2 rows then close — remaining rows drained silently.
  assert_true(reader.has_next())
  let _ = reader.data_row()
  assert_true(reader.has_next())
  let _ = reader.data_row()
  let tag = reader.close()
  assert_eq(tag.command(), "SELECT")
}

///|
async test "ext_double_close" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let reader = conn.execute_params("SELECT 1 AS n", [], [], [], [])
  let tag1 = reader.close()
  let tag2 = reader.close()
  assert_eq(tag1.command(), tag2.command())
}

///|
async test "ext_syntax_error" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  (conn.execute_params("SELEC $1", [Some(enc("1"))], [], [], []).read()
  |> ignore) catch {
    WireError::PgServer(s) =>
      inspect(
        s,
        content=(
          #|syntax error at or near "SELEC"
        ),
      )
    _ => fail("expected PgServer error")
  }
}

///|
async test "ext_param_count_mismatch" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  // param_oids length must be 0, 1, or equal to param_values count
  (conn
  .execute_params(
    "SELECT $1::int + $2::int",
    [Some(enc("1")), Some(enc("2"))],
    [23, 23, 23],
    [],
    [],
  )
  .close()
  |> ignore) catch {
    WireError::Parse(s) =>
      inspect(
        s,
        content=(
          #|param_oids length (3) must be 0, 1, or equal to param_values (2)
        ),
      )
    _ => fail("expected Parse error")
  }
}

///|
async test "ext_multiple_executions" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  // Run the same parameterized query multiple times.
  for i = 1; i <= 3; i = i + 1 {
    let reader = conn.execute_params(
      "SELECT $1::int AS n",
      [Some(enc(i.to_string()))],
      [23],
      [],
      [],
    )
    let result = reader.read()
    match result.rows[0] {
      [Some(bs)] => assert_eq(@utf8.decode(bs), i.to_string())
      _ => fail("expected one column")
    }
    assert_eq(result.tag.command(), "SELECT")
  }
}

// ---------------------------------------------------------------------------
// Prepare tests
// ---------------------------------------------------------------------------

///|
async test "prepare_select" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let desc = conn.prepare("stmt_sel", "SELECT $1::int + $2::int AS sum", [
    23, 23,
  ])
  assert_eq(desc.name, "stmt_sel")
  assert_eq(desc.param_oids.length(), 2)
  assert_eq(desc.fields.length(), 1)
  assert_eq(desc.fields[0].name, "sum")
}

///|
async test "prepare_no_params" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let desc = conn.prepare("", "SELECT 1 AS n", [])
  assert_eq(desc.param_oids.length(), 0)
  assert_eq(desc.fields.length(), 1)
  assert_eq(desc.fields[0].name, "n")
}

///|
async test "prepare_insert" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let _ = conn
    .simple_query("CREATE TEMP TABLE _prep_ins (x int, y text)")
    .close()
  let desc = conn.prepare(
    "stmt_ins",
    "INSERT INTO _prep_ins (x, y) VALUES ($1, $2)",
    [23, 25],
  )
  assert_eq(desc.param_oids.length(), 2)
  assert_eq(desc.fields.length(), 0)
}

///|
async test "prepare_syntax_error" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  (conn.prepare("bad", "SELEC 1", []) |> ignore) catch {
    WireError::PgServer(s) =>
      inspect(
        s,
        content=(
          #|syntax error at or near "SELEC"
        ),
      )
    _ => fail("expected PgServer error")
  }
}

// ---------------------------------------------------------------------------
// execute_prepared / execute_statement tests
// ---------------------------------------------------------------------------

///|
async test "exec_prepared_select" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  conn.prepare("ep_sel", "SELECT $1::int + $2::int AS sum", [23, 23]) |> ignore
  let reader = conn.execute_prepared(
    "ep_sel",
    [Some(enc("10")), Some(enc("32"))],
    [],
    [],
  )
  assert_eq(reader.columns().length(), 1)
  assert_eq(reader.columns()[0].name, "sum")
  assert_true(reader.has_next())
  let row = reader.data_row()
  assert_true(row is [Some(bs)] && @utf8.decode(bs) == "42")
  let tag = reader.close()
  assert_eq(tag.command(), "SELECT")
}

///|
async test "exec_prepared_insert" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let _ = conn.simple_query("CREATE TEMP TABLE _epp_ins (x int)").close()
  conn.prepare("ep_ins", "INSERT INTO _epp_ins VALUES ($1)", [23]) |> ignore
  let tag = conn.execute_prepared("ep_ins", [Some(enc("42"))], [], []).close()
  assert_eq(tag.command(), "INSERT")
  assert_true(tag.rows_affected() is Some(1))
}

///|
async test "exec_statement_select" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let desc = conn.prepare(
    "es_sel",
    "SELECT $1::int * i AS prod FROM generate_series(1, 3) AS i",
    [23],
  )
  // execute_statement skips Describe — uses pre-known columns from desc
  let reader = conn.execute_statement(desc, [Some(enc("10"))], [], [])
  // Columns are available without a Describe round-trip
  assert_eq(reader.columns().length(), 1)
  assert_eq(reader.columns()[0].name, "prod")
  let result = reader.read()
  assert_eq(result.rows.length(), 3)
  assert_eq(result.tag.command(), "SELECT")
}

///|
async test "exec_statement_no_columns" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let _ = conn.simple_query("CREATE TEMP TABLE _esp_ins (x int)").close()
  let desc = conn.prepare("es_ins", "INSERT INTO _esp_ins VALUES ($1)", [23])
  assert_eq(desc.fields.length(), 0)
  let tag = conn.execute_statement(desc, [Some(enc("99"))], [], []).close()
  assert_eq(tag.command(), "INSERT")
  assert_true(tag.rows_affected() is Some(1))
}

// ---------------------------------------------------------------------------
// execute_prepared — more tests
// ---------------------------------------------------------------------------

///|
async test "exec_prepared_multi_exec" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  conn.prepare("epm", "SELECT $1::int * 2 AS doubled", [23]) |> ignore
  for i = 1; i <= 3; i = i + 1 {
    let reader = conn.execute_prepared("epm", [Some(enc(i.to_string()))], [], [])
    let result = reader.read()
    match result.rows[0] {
      [Some(bs)] => assert_eq(@utf8.decode(bs), (i * 2).to_string())
      _ => fail("expected one column")
    }
  }
}

///|
async test "exec_prepared_null_param" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  conn.prepare("epn", "SELECT $1::text IS NULL AS is_null", [25]) |> ignore
  let reader = conn.execute_prepared("epn", [None], [], [])
  assert_true(reader.has_next())
  let row = reader.data_row()
  assert_true(row is [Some(bs)] && @utf8.decode(bs) == "t")
  reader.close() |> ignore
}

///|
async test "exec_prepared_no_params" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  conn.prepare("ep0", "SELECT 42 AS answer", []) |> ignore
  let result = conn.execute_prepared("ep0", [], [], []).read()
  match result.rows[0] {
    [Some(bs)] => assert_eq(@utf8.decode(bs), "42")
    _ => fail("expected one column")
  }
}

///|
async test "exec_prepared_unknown_statement" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  (conn.execute_prepared("no_such_stmt", [], [], []).close() |> ignore) catch {
    WireError::PgServer(_) => ()
    _ => fail("expected PgServer error")
  }
}

///|
async test "exec_prepared_pull" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  conn.prepare("epp", "SELECT generate_series(1, $1::int) AS x", [23]) |> ignore
  let reader = conn.execute_prepared("epp", [Some(enc("4"))], [], [])
  let values : Array[String] = []
  while reader.has_next() {
    match reader.data_row() {
      [Some(bs)] => values.push(@utf8.decode(bs))
      _ => fail("expected one column")
    }
  }
  assert_true(values == ["1", "2", "3", "4"])
  reader.close() |> ignore
}

///|
async test "exec_prepared_close_early" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  conn.prepare("epc", "SELECT generate_series(1, 10) AS x", []) |> ignore
  let reader = conn.execute_prepared("epc", [], [], [])
  assert_true(reader.has_next())
  let _ = reader.data_row()
  assert_true(reader.has_next())
  let _ = reader.data_row()
  let tag = reader.close()
  assert_eq(tag.command(), "SELECT")
}

// ---------------------------------------------------------------------------
// execute_statement — more tests
// ---------------------------------------------------------------------------

///|
async test "exec_statement_multi_exec" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let desc = conn.prepare("esm", "SELECT $1::text || '!' AS excited", [25])
  for i = 0; i < 3; i = i + 1 {
    let word = match i {
      0 => "hello"
      1 => "world"
      _ => "moon"
    }
    let reader = conn.execute_statement(desc, [Some(enc(word))], [], [])
    let result = reader.read()
    match result.rows[0] {
      [Some(bs)] => assert_eq(@utf8.decode(bs), word + "!")
      _ => fail("expected one column")
    }
  }
}

///|
async test "exec_statement_pull" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let desc = conn.prepare(
    "esp",
    "SELECT n FROM generate_series(1, $1::int) AS n WHERE n % 2 = 0",
    [23],
  )
  let reader = conn.execute_statement(desc, [Some(enc("10"))], [], [])
  let values : Array[String] = []
  while reader.has_next() {
    match reader.data_row() {
      [Some(bs)] => values.push(@utf8.decode(bs))
      _ => fail("expected one column")
    }
  }
  assert_true(values == ["2", "4", "6", "8", "10"])
  reader.close() |> ignore
}

///|
async test "exec_statement_batch" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let desc = conn.prepare(
    "esb",
    "SELECT $1::int * n FROM generate_series(1, 3) AS n",
    [23],
  )
  let result = conn.execute_statement(desc, [Some(enc("7"))], [], []).read()
  assert_eq(result.columns[0].name, "?column?")
  assert_eq(result.rows.length(), 3)
  match result.rows {
    [r1, r2, r3] =>
      assert_true(
        [
          @utf8.decode(r1[0].unwrap()),
          @utf8.decode(r2[0].unwrap()),
          @utf8.decode(r3[0].unwrap()),
        ] ==
        ["7", "14", "21"],
      )
    _ => fail("expected 3 rows")
  }
  assert_eq(result.tag.command(), "SELECT")
}

///|
async test "exec_statement_returning" {
  let conn = connect(
    "postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test",
  )
  defer conn.close()
  let _ = conn
    .simple_query("CREATE TEMP TABLE _esr (id serial primary key, val text)")
    .close()
  let desc = conn.prepare(
    "esr",
    "INSERT INTO _esr (val) VALUES ($1) RETURNING id, val",
    [25],
  )
  let reader = conn.execute_statement(desc, [Some(enc("xyz"))], [], [])
  assert_eq(reader.columns().length(), 2)
  assert_eq(reader.columns()[0].name, "id")
  assert_eq(reader.columns()[1].name, "val")
  assert_true(reader.has_next())
  let row = reader.data_row()
  assert_true(row is [Some(_), Some(v)] && @utf8.decode(v) == "xyz")
  let tag = reader.close()
  assert_eq(tag.command(), "INSERT")
}
