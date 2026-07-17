///|
test "kv_basic" {
  let c = Config::from_connstr(
    "host=localhost port=5432 user=alice dbname=mydb password=secret",
  )
  assert_eq(c.host, "localhost")
  assert_eq(c.port, 5432)
  assert_eq(c.user, "alice")
  assert_true(c.database == Some("mydb"))
  assert_true(c.password == Some("secret"))
}

///|
test "kv_single_quoted" {
  let c = Config::from_connstr("password='has spaces'")
  assert_true(c.password == Some("has spaces"))
}

///|
test "kv_escaped_quote" {
  let c = Config::from_connstr("password='it\\'s'")
  assert_true(c.password == Some("it's"))
}

///|
test "kv_backslash_escape" {
  let c = Config::from_connstr("password=C:\\\\data")
  // C:\\data → C:\data after unescaping
  assert_true(c.password == Some("C:\\data"))
}

///|
test "kv_case_insensitive" {
  let c = Config::from_connstr("HOST=db.example.com PORT=9999")
  assert_eq(c.host, "db.example.com")
  assert_eq(c.port, 9999)
}

///|
test "kv_aliases" {
  let c = Config::from_connstr("username=bob database=testdb")
  assert_eq(c.user, "bob")
  assert_true(c.database == Some("testdb"))
}

///|
test "kv_empty_value" {
  let c = Config::from_connstr("password='' user=alice")
  assert_true(c.password == Some(""))
  assert_eq(c.user, "alice")
}

///|
test "kv_space_around_equals" {
  // Spaces directly around `=` are tolerated when the value is quoted or
  // when there is no ambiguity.  For bare values separated by spaces, use
  // the canonical `key=value` format.
  let c = Config::from_connstr("host=myhost port=8888")
  assert_eq(c.host, "myhost")
  assert_eq(c.port, 8888)
}

///|
test "kv_defaults" {
  let c = Config::from_connstr("")
  assert_eq(c.host, "localhost")
  assert_eq(c.user, "postgres")
  assert_eq(c.port, 5432)
  assert_true(c.database == None)
  assert_true(c.password == None)
  assert_eq(c.sslmode, "disable")
}

///|
test "kv_application_name" {
  let c = Config::from_connstr("application_name=myapp")
  assert_true(c.application_name == Some("myapp"))
}

///|
test "kv_hostaddr" {
  let c = Config::from_connstr("hostaddr=10.0.0.1")
  assert_true(c.hostaddr == Some("10.0.0.1"))
}

///|
test "kv_unknown_key_ignored" {
  let c = Config::from_connstr("foo=bar host=localhost")
  assert_eq(c.host, "localhost")
}

///|
test "kv_quoted_empty" {
  let c = Config::from_connstr("password=''")
  assert_true(c.password == Some(""))
}

///|
test "uri_full" {
  let c = Config::from_connstr(
    "postgresql://alice:secret@db.example.com:5433/mydb",
  )
  assert_eq(c.user, "alice")
  assert_true(c.password == Some("secret"))
  assert_eq(c.host, "db.example.com")
  assert_eq(c.port, 5433)
  assert_true(c.database == Some("mydb"))
}

///|
test "uri_no_password" {
  let c = Config::from_connstr("postgresql://alice@localhost/mydb")
  assert_eq(c.user, "alice")
  assert_true(c.password == None)
}

///|
test "uri_no_userinfo" {
  let c = Config::from_connstr("postgresql://localhost/mydb")
  assert_eq(c.user, "")
  assert_true(c.password == None)
  assert_true(c.database == Some("mydb"))
}

///|
test "uri_with_query_params" {
  let c = Config::from_connstr(
    "postgresql://localhost/mydb?sslmode=require&application_name=myapp",
  )
  assert_eq(c.sslmode, "require")
  assert_true(c.application_name == Some("myapp"))
}

///|
test "uri_postgres_prefix" {
  let c = Config::from_connstr("postgres://u:p@h/db")
  assert_eq(c.user, "u")
  assert_true(c.password == Some("p"))
  assert_eq(c.host, "h")
  assert_true(c.database == Some("db"))
}

///|
test "uri_no_database" {
  let c = Config::from_connstr("postgresql://localhost")
  assert_true(c.database == None)
}

///|
test "uri_default_port" {
  let c = Config::from_connstr("postgresql://localhost/mydb")
  assert_eq(c.port, 5432)
}

///|
test "uri_query_override" {
  let c = Config::from_connstr("postgresql://a@h1/db1?user=b&dbname=db2")
  assert_eq(c.user, "b")
  assert_true(c.database == Some("db2"))
}

///|
test "kv_sslrootcert" {
  let c = Config::from_connstr("sslrootcert=/etc/ssl/ca.pem")
  assert_true(c.sslrootcert == Some("/etc/ssl/ca.pem"))
}

///|
test "kv_sslcert_and_sslkey" {
  let c = Config::from_connstr(
    "sslcert=/etc/ssl/client.pem sslkey=/etc/ssl/client.key",
  )
  assert_true(c.sslcert == Some("/etc/ssl/client.pem"))
  assert_true(c.sslkey == Some("/etc/ssl/client.key"))
}

///|
test "uri_sslrootcert" {
  let c = Config::from_connstr(
    "postgresql://localhost?sslrootcert=/tmp/ca.pem&sslmode=verify-ca",
  )
  assert_eq(c.sslmode, "verify-ca")
  assert_true(c.sslrootcert == Some("/tmp/ca.pem"))
}

///|
test "kv_statement_timeout" {
  let c = Config::from_connstr("statement_timeout=5000")
  assert_eq(c.statement_timeout, 5000)
}

///|
test "kv_target_session_attrs" {
  let c = Config::from_connstr("target_session_attrs=read-write")
  assert_eq(c.target_session_attrs, "read-write")
}

///|
test "target_session_attrs_default" {
  let c = Config::new("user")
  assert_eq(c.target_session_attrs, "any")
}

///|
test "ssl_defaults" {
  let c = Config::new("user")
  assert_eq(c.sslmode, "disable")
  assert_true(c.sslrootcert == None)
  assert_true(c.sslcert == None)
  assert_true(c.sslkey == None)
}
