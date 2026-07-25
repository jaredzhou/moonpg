///|
/// Build a `BEGIN` SQL string from options.
pub fn build_begin_sql(opts : TxOptions) -> String {
  let parts : Array[String] = []
  match opts.isolation_level {
    Some(level) => parts.push("ISOLATION LEVEL \{level.to_sql()}")
    None => ()
  }
  match opts.read_only {
    Some(true) => parts.push("READ ONLY")
    Some(false) => parts.push("READ WRITE")
    None => ()
  }
  match opts.deferrable {
    Some(true) => parts.push("DEFERRABLE")
    Some(false) => parts.push("NOT DEFERRABLE")
    None => ()
  }
  if parts.is_empty() {
    "BEGIN"
  } else {
    "BEGIN \{parts.join(" ")}"
  }
}

///|
pub impl TxBeginner for Connection with fn begin_tx(
  self : Connection,
  opts? : TxOptions,
) -> &Tx raise PgError {
  Connection::execute(
    self,
    build_begin_sql(
      match opts {
        Some(o) => o
        None => TxOptions::default()
      },
    ),
  )
  |> ignore
  DbTx::{ conn: self }
}

///|
pub impl QueryExecutor for DbTx with fn query(
  self : DbTx,
  sql : String,
  params? : Array[&ToValue],
) -> &Rows raise PgError {
  Connection::query(self.conn, sql, params?)
}

///|
pub impl QueryExecutor for DbTx with fn query_one(
  self : DbTx,
  sql : String,
  params? : Array[&ToValue],
) -> Row raise PgError {
  Connection::query_one(self.conn, sql, params?)
}

///|
pub impl QueryExecutor for DbTx with fn execute(
  self : DbTx,
  sql : String,
  params? : Array[&ToValue],
) -> ExecResult raise PgError {
  Connection::execute(self.conn, sql, params?)
}

///|
pub impl QueryExecutor for DbTx with fn close(self : DbTx) -> Unit {
  self.conn.close()
}

///|
pub impl Tx for DbTx with fn commit(self : DbTx) -> Unit raise PgError {
  Connection::execute(self.conn, "COMMIT") |> ignore
}

///|
pub impl Tx for DbTx with fn rollback(self : DbTx) -> Unit raise PgError {
  Connection::execute(self.conn, "ROLLBACK") |> ignore
}
