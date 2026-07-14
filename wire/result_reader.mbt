///|
/// All rows from a query, collected eagerly.
pub struct Result {
  columns : Array[FieldDescription]
  rows : Array[Array[Bytes?]]
  tag : CommandTag
}

///|
/// Pull-based query result reader.
///
/// Obtained from `RawConn::simple_query`.  Two usage styles:
///
/// **Pull** — iterate row by row:
/// ```moonbit nocheck
/// while r.has_next() { let row = r.data_row(); ... }
/// let tag = r.close()
/// ```
///
/// **Batch** — read everything at once:
/// ```moonbit nocheck
/// let result = r.read()
/// ```
pub struct ResultReader {
  conn : RawConn
  columns : Array[FieldDescription]
  mut row_values : Array[Bytes?]?
  mut closed : Bool
  mut tag : CommandTag?
}

///|
pub fn ResultReader::columns(self : ResultReader) -> Array[FieldDescription] {
  self.columns
}

///|
/// Wait for the next row. Returns `true` if a row is available (call `data_row`
/// to get it), `false` when all rows have been consumed.
///
/// On `false` the remaining messages up to `ReadyForQuery` have already been
/// drained and the connection unlocked.
pub async fn ResultReader::has_next(
  self : ResultReader,
) -> Bool raise WireError {
  if self.closed {
    return false
  }
  if self.row_values is Some(_) {
    return true
  }
  for ;; {
    let msg = self.conn.receive()
    match msg {
      NoticeResponse(_) => continue
      ErrorResponse(e) => {
        self.closed = true
        let msg = e.message().unwrap_or("unknown")
        self.conn.end_query()
        raise WireError::PgServer(msg)
      }
      DataRow(dr) => {
        self.row_values = Some(dr.values)
        return true
      }
      CommandComplete(cc) => {
        self.tag = Some(cc.tag)
        self.closed = true
        self.conn.end_query()
        return false
      }
      EmptyQueryResponse(_) => {
        self.tag = Some(CommandTag::new(""))
        self.closed = true
        self.conn.end_query()
        return false
      }
      _ => continue
    }
  }
}

///|
/// Return the row cached by the last `has_next()` call.
/// Panics if `has_next()` was not called or returned `false`.
pub fn ResultReader::data_row(
  self : ResultReader,
) -> Array[Bytes?] raise WireError {
  match self.row_values {
    Some(row) => {
      self.row_values = None
      row
    }
    None =>
      raise WireError::InvalidMessage(
        "data_row: no pending row — call has_next() first",
      )
  }
}

///|
/// Eagerly read all remaining rows into a `Result`.
pub async fn ResultReader::read(self : ResultReader) -> Result raise WireError {
  let rows : Array[Array[Bytes?]] = []
  while self.has_next() {
    rows.push(self.data_row())
  }
  { columns: self.columns, rows, tag: self.tag.unwrap_or(CommandTag::new("")) }
}

///|
/// Close the reader: drain remaining rows and messages, unlock, return tag.
/// Safe to call multiple times.
pub async fn ResultReader::close(
  self : ResultReader,
) -> CommandTag raise WireError {
  if self.closed {
    return self.tag.unwrap_or(CommandTag::new(""))
  }
  self.row_values = None
  while self.has_next() {
    let _ = self.data_row()
  }
  self.tag.unwrap_or(CommandTag::new(""))
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

///|
/// Reject SQL strings that contain more than one statement.
fn check_single_statement(sql : String) -> Unit raise WireError {
  let mut count = 0
  for part in sql.split(";") {
    if part.trim().length() > 0 {
      count = count + 1
    }
  }
  guard count <= 1 else {
    raise WireError::Parse(
      "simple_query: multiple statements not supported — use extended query for multi-statement batches",
    )
  }
}
