///|
/// Raw PostgreSQL wire-protocol connection.
///
/// Handles TCP connection, SSL negotiation, startup message exchange,
/// authentication, and message send/receive. After a successful handshake
/// the connection is in the `Idle` state and can be used for queries.
pub struct RawConn {
  stream : @socket.Tcp
  /// When `true`, every sent and received message is traced to stderr.
  mut trace : Bool
  /// Server host, stored for cancel requests.
  host : String
  /// Server port, stored for cancel requests.
  port : Int
  /// Server parameters reported during startup (ParameterStatus messages).
  params : @hashmap.HashMap[String, String]
  /// Backend process ID.
  pid : Int
  /// Backend secret key (for cancel requests).
  secret_key : Int
  /// Current transaction status from the last `ReadyForQuery`.
  mut tx_status : TransactionStatus
  /// Current connection lifecycle state.
  mut status : ConnStatus
}

///|
/// Connection lifecycle states.
pub enum ConnStatus {
  Connecting
  Closed
  Idle
  Busy
} derive(Debug, Eq)

///|
/// Well-known server parameter names.
pub const PARAM_SERVER_VERSION : String = "server_version"

///|
pub const PARAM_SERVER_ENCODING : String = "server_encoding"

///|
pub const PARAM_CLIENT_ENCODING : String = "client_encoding"

///|
pub const PARAM_TIMEZONE : String = "TimeZone"

// ---------------------------------------------------------------------------
// Connection establishment
// ---------------------------------------------------------------------------

///|
pub async fn connect(connstr : String) -> RawConn raise WireError {
  connect_config(Config::from_connstr(connstr))
}

///|
/// Connect using a `Config` struct.
pub async fn connect_config(config : Config) -> RawConn raise WireError {
  let addr = @socket.Addr::resolve(config.host, port=config.port) catch {
    e => raise WireError::IO("resolve \{config.host}:\{config.port}: \{e}")
  }
  let tcp = @socket.Tcp::connect(addr) catch {
    e => raise WireError::IO("connect \{config.host}:\{config.port}: \{e}")
  }
  let conn = RawConn::{
    stream: tcp,
    trace: config.trace,
    host: config.host,
    port: config.port,
    params: @hashmap.HashMap([]),
    pid: 0,
    secret_key: 0,
    tx_status: Idle,
    status: Connecting,
  }

  // SSL negotiation
  let ssl = config.sslmode
  if ssl == "require" || ssl == "prefer" {
    if ssl == "require" {
      raise WireError::Connect(
        "sslmode=require requested but TLS is not yet implemented",
      )
    }
  }

  // Build and send StartupMessage
  let startup_params : Array[ConnParam] = []
  startup_params.push(ConnParam::{ key: "user", value: config.user })
  let db = match config.database {
    Some(d) => d
    None => config.user
  }
  startup_params.push(ConnParam::{ key: "database", value: db })
  let startup = StartupMessage::{ version: V3_2, params: startup_params }
  conn.send(startup)

  // Process authentication + parameter messages until ReadyForQuery
  let params_map : @hashmap.HashMap[String, String] = @hashmap.HashMap([])
  let mut pid = 0
  let mut secret_key = 0

  for ;; {
    let msg = conn.receive()
    match msg {
      AuthenticationOk(_) => ()
      AuthenticationCleartextPassword(_) =>
        match config.password {
          Some(pw) => {
            let _ = conn.send(PasswordMessage::{ password: pw })
          }
          None =>
            raise WireError::Auth(
              "server requested cleartext password but none provided",
            )
        }
      AuthenticationMD5Password(m) =>
        match config.password {
          Some(pw) => {
            let md5_pass = compute_md5_password(pw, config.user, m.salt)
            let _ = conn.send(PasswordMessage::{ password: md5_pass })
          }
          None =>
            raise WireError::Auth(
              "server requested MD5 password but none provided",
            )
        }
      AuthenticationSASL(m) =>
        handle_sasl_auth(conn, config.user, m.mechanisms, config.password)
      AuthenticationSASLContinue(_) =>
        raise WireError::Auth("unexpected SASLContinue during startup")
      AuthenticationSASLFinal(_) =>
        raise WireError::Auth("unexpected SASLFinal during startup")
      ParameterStatus(m) => params_map.set(m.name, m.value)
      BackendKeyData(m) => {
        pid = m.pid
        secret_key = m.secret_key
      }
      ReadyForQuery(rfq) => {
        conn.tx_status = rfq.status
        break
      }
      ErrorResponse(m) => {
        let msg = m.message().unwrap_or("unknown error")
        raise WireError::Auth("connection error: \{msg}")
      }
      NoticeResponse(m) =>
        if conn.trace {
          println("Notice: \{m.message().unwrap_or("")}")
        }
      _ => ()
    }
  }

  { ..conn, params: params_map, pid, secret_key, status: Idle }
}

// ---------------------------------------------------------------------------
// Message send / receive
// ---------------------------------------------------------------------------

///|
/// Send any frontend message.
///
/// Calls `msg.encode()` to get the wire-format bytes, then writes them to the
/// socket. For `StartupMessage` and `SSLRequest` the message has no type byte;
/// for all other messages the type byte is included.
pub async fn[M : Message] RawConn::send(
  self : RawConn,
  msg : M,
) -> Unit raise WireError {
  let data = msg.encode() catch {
    WireError::InvalidMessage(m) => {
      self.close()
      raise WireError::InvalidMessage(m)
    }
    _ => {
      self.close()
      raise WireError::InvalidMessage("unexpected error")
    }
  }

  if self.trace {
    println(">>> \{msg.describe()} (\{data.length()} bytes)")
  }

  self.stream.write(data) catch {
    e => {
      self.close()
      raise WireError::IO("write: \{e}")
    }
  }
}

///|
/// Core receive logic without close-on-error.  Separated so the public
/// `receive` wrapper can add `close()` in one place.
async fn RawConn::receive_inner(
  self : RawConn,
) -> BackendMessage raise WireError {
  // Read type byte
  let type_byte_arr = self.stream.read_exactly(1) catch {
    e => raise WireError::IO("read type byte: \{e}")
  }
  let type_byte = type_byte_arr[0]
  // Read length (includes self — 4 bytes)
  let len_bytes = self.stream.read_exactly(4) catch {
    e => raise WireError::IO("read length: \{e}")
  }
  guard len_bytes is [i32be(len)] else {
    raise WireError::InvalidMessage("invalid backend message length")
  }
  let payload_len = len - 4
  // Read payload
  let payload = if payload_len > 0 {
    self.stream.read_exactly(payload_len) catch {
      e => raise WireError::IO("read payload: \{e}")
    }
  } else {
    Bytes::default()
  }

  let msg = match type_byte {
    b'R' => {
      guard payload is [u32be(code), .. rest] else {
        raise WireError::InvalidMessage(
          "invalid Authentication message payload",
        )
      }
      match code {
        0 =>
          AuthenticationOk(
            AuthenticationOk::decode(rest) catch {
              WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
              _ => raise WireError::InvalidMessage("unexpected error")
            },
          )
        3 =>
          AuthenticationCleartextPassword(
            AuthenticationCleartextPassword::decode(rest) catch {
              WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
              _ => raise WireError::InvalidMessage("unexpected error")
            },
          )
        5 =>
          AuthenticationMD5Password(
            AuthenticationMD5Password::decode(rest) catch {
              WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
              _ => raise WireError::InvalidMessage("unexpected error")
            },
          )
        10 =>
          AuthenticationSASL(
            AuthenticationSASL::decode(rest) catch {
              WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
              _ => raise WireError::InvalidMessage("unexpected error")
            },
          )
        11 =>
          AuthenticationSASLContinue(
            AuthenticationSASLContinue::decode(rest) catch {
              WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
              _ => raise WireError::InvalidMessage("unexpected error")
            },
          )
        12 =>
          AuthenticationSASLFinal(
            AuthenticationSASLFinal::decode(rest) catch {
              WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
              _ => raise WireError::InvalidMessage("unexpected error")
            },
          )
        _ => Unknown(type_byte, payload)
      }
    }
    b'K' =>
      BackendKeyData(
        BackendKeyData::decode(payload) catch {
          WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
          _ => raise WireError::InvalidMessage("unexpected error")
        },
      )
    b'Z' =>
      ReadyForQuery(
        ReadyForQuery::decode(payload) catch {
          WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
          _ => raise WireError::InvalidMessage("unexpected error")
        },
      )
    b'S' =>
      ParameterStatus(
        ParameterStatus::decode(payload) catch {
          WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
          _ => raise WireError::InvalidMessage("unexpected error")
        },
      )
    b'E' =>
      ErrorResponse(
        ErrorResponse::decode(payload) catch {
          WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
          _ => raise WireError::InvalidMessage("unexpected error")
        },
      )
    b'N' =>
      NoticeResponse(
        NoticeResponse::decode(payload) catch {
          WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
          _ => raise WireError::InvalidMessage("unexpected error")
        },
      )
    b'T' =>
      RowDescription(
        RowDescription::decode(payload) catch {
          WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
          _ => raise WireError::InvalidMessage("unexpected error")
        },
      )
    b'D' =>
      DataRow(
        DataRow::decode(payload) catch {
          WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
          _ => raise WireError::InvalidMessage("unexpected error")
        },
      )
    b'C' =>
      CommandComplete(
        CommandComplete::decode(payload) catch {
          WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
          _ => raise WireError::InvalidMessage("unexpected error")
        },
      )
    b'I' =>
      EmptyQueryResponse(
        EmptyQueryResponse::decode(payload) catch {
          WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
          _ => raise WireError::InvalidMessage("unexpected error")
        },
      )
    b'1' =>
      ParseComplete(
        ParseComplete::decode(payload) catch {
          WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
          _ => raise WireError::InvalidMessage("unexpected error")
        },
      )
    b'2' =>
      BindComplete(
        BindComplete::decode(payload) catch {
          WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
          _ => raise WireError::InvalidMessage("unexpected error")
        },
      )
    b'3' =>
      CloseComplete(
        CloseComplete::decode(payload) catch {
          WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
          _ => raise WireError::InvalidMessage("unexpected error")
        },
      )
    b't' =>
      ParameterDescription(
        ParameterDescription::decode(payload) catch {
          WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
          _ => raise WireError::InvalidMessage("unexpected error")
        },
      )
    b'n' =>
      NoData(
        NoData::decode(payload) catch {
          WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
          _ => raise WireError::InvalidMessage("unexpected error")
        },
      )
    b's' =>
      PortalSuspended(
        PortalSuspended::decode(payload) catch {
          WireError::InvalidMessage(m) => raise WireError::InvalidMessage(m)
          _ => raise WireError::InvalidMessage("unexpected error")
        },
      )
    _ => Unknown(type_byte, payload)
  }

  if self.trace {
    let total = 1 + 4 + payload.length()
    println("<<< \{msg.describe()} (\{total} bytes)")
  }

  msg
}

///|
/// Receive the next backend message from the server.
///
/// Reads the 1-byte type tag, then the 4-byte length, then the payload,
/// and decodes into a `BackendMessage`.  Closes the connection on any
/// I/O or protocol error.
pub async fn RawConn::receive(self : RawConn) -> BackendMessage raise WireError {
  self.receive_inner() catch {
    WireError::IO(m) => {
      self.close()
      raise WireError::IO(m)
    }
    WireError::InvalidMessage(m) => {
      self.close()
      raise WireError::InvalidMessage(m)
    }
    err => raise err
  }
}

// ---------------------------------------------------------------------------
// Query lifecycle
// ---------------------------------------------------------------------------

///|
/// Begin a query: lock the connection and send the SQL.
///
/// After `start_query`, read responses via `receive`, then
/// call `end_query` to drain remaining messages and unlock.
pub async fn RawConn::start_query(
  self : RawConn,
  sql : String,
) -> Unit raise WireError {
  check_single_statement(sql)
  self.lock()
  self.send(Query::{ sql, })
}

///|
/// Drain remaining messages until `ReadyForQuery`, update `tx_status`, and
/// unlock the connection. Pairs with `start_query`.
///
/// If an `ErrorResponse` is encountered during drain, it finishes draining
/// through to `ReadyForQuery` and then raises `PgServer`.
pub async fn RawConn::end_query(self : RawConn) -> Unit raise WireError {
  for ;; {
    let msg = self.receive()
    match msg {
      ReadyForQuery(rfq) => {
        self.tx_status = rfq.status
        break
      }
      ErrorResponse(e) => {
        let msg = e.message().unwrap_or("unknown")
        self.receive() |> ignore
        self.unlock()
        raise WireError::PgServer(msg)
      }
      _ => ()
    }
  }
  self.unlock()
}

// ---------------------------------------------------------------------------
// Simple query
// ---------------------------------------------------------------------------

///|
/// Execute a simple query and return a `ResultReader`.
pub async fn RawConn::simple_query(
  self : RawConn,
  sql : String,
) -> ResultReader raise WireError {
  self.start_query(sql)

  for ;; {
    let msg = self.receive()
    match msg {
      NoticeResponse(_) => continue
      ErrorResponse(e) => {
        let msg = e.message().unwrap_or("unknown")
        self.end_query()
        raise WireError::PgServer(msg)
      }
      RowDescription(rd) =>
        return ResultReader::{
          conn: self,
          columns: rd.columns,
          row_values: None,
          closed: false,
          tag: None,
        }
      CommandComplete(cc) => {
        self.end_query()
        return ResultReader::{
          conn: self,
          columns: [],
          row_values: None,
          closed: true,
          tag: Some(cc.tag),
        }
      }
      EmptyQueryResponse(_) => {
        self.end_query()
        return ResultReader::{
          conn: self,
          columns: [],
          row_values: None,
          closed: true,
          tag: Some(CommandTag::new("")),
        }
      }
      _ =>
        raise WireError::InvalidMessage(
          "simple_query: unexpected first message",
        )
    }
  }
  raise WireError::InvalidMessage("simple_query: unreachable")
}

// ---------------------------------------------------------------------------
// Connection management
// ---------------------------------------------------------------------------

///|
pub fn RawConn::tx_status(self : RawConn) -> TransactionStatus {
  self.tx_status
}

///|
pub fn RawConn::status(self : RawConn) -> ConnStatus {
  self.status
}

///|
pub fn RawConn::param(self : RawConn, name : String) -> String? {
  self.params.get(name)
}

///|
pub fn RawConn::backend_pid(self : RawConn) -> Int {
  self.pid
}

///|
pub fn RawConn::close(self : RawConn) -> Unit {
  self.status = Closed
  self.stream.close()
}

///|
pub fn RawConn::is_closed(self : RawConn) -> Bool {
  match self.status {
    Idle | Busy => false
    _ => true
  }
}

///|
pub fn RawConn::is_busy(self : RawConn) -> Bool {
  self.status == Busy
}

///|
fn RawConn::lock(self : RawConn) -> Unit raise WireError {
  match self.status {
    Busy => raise WireError::Connect("conn is busy")
    Closed => raise WireError::Connect("conn is closed")
    Connecting => raise WireError::Connect("conn is still connecting")
    Idle => ()
  }
  self.status = Busy
}

///|
fn RawConn::unlock(self : RawConn) -> Unit raise WireError {
  match self.status {
    Busy => self.status = Idle
    Closed => ()
    _ => raise WireError::Connect("BUG: cannot unlock unlocked connection")
  }
}

///|
/// Send a Flush message to the server.
///
/// Tells the server to flush any buffered output. Used in the extended query
/// protocol.
pub async fn RawConn::flush(self : RawConn) -> Unit raise WireError {
  self.send(Flush::{  })
}

///|
/// Send Terminate and close.
pub async fn RawConn::terminate(self : RawConn) -> Unit {
  let data = Terminate::encode(Terminate::{  }) catch {
    _ => {
      self.stream.close()
      return
    }
  }
  self.stream.write(data)
  self.stream.close()
}

///|
/// Best-effort emergency close for unrecoverable errors.
///
/// Use this when the connection cannot be safely reused:
///
/// * I/O errors — broken pipe, connection reset, unexpected EOF.
/// * Protocol desynchronisation — invalid message length/type, the stream
///   cannot be trusted any more.
/// * Authentication failures.
/// * Server `FATAL` / `PANIC` errors (as opposed to recoverable `ERROR`).
///
/// What it does:
///
/// 1. Immediately marks the connection `Closed` so nothing else tries to
///    use it.
/// 2. Sends a cancel request on a **new** TCP connection so the server
///    stops any in-flight query.
/// 3. Sends `Terminate` on the original connection.
/// 4. Closes the socket.
///
/// Steps 2 and 3 run concurrently via `@async.all`.  All errors are
/// silently ignored — this is fire-and-forget cleanup.
pub async fn RawConn::try_close(self : RawConn) -> Unit {
  if self.status == Closed {
    return
  }
  self.status = Closed
  let host = self.host
  let port = self.port
  let pid = self.pid
  let secret_key = self.secret_key
  let stream = self.stream
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      @async.sleep(1000 * 10)
      group.return_immediately(())
    }
    group.spawn_bg() <| () => { cancel_request(host, port, pid, secret_key) }
    let data = Terminate::encode(Terminate::{  }) catch { _ => return }
    stream.write(data)
  }
  stream.close()
}

///|
/// Read a single byte from the stream. Used for the SSL negotiation response
/// (`S` or `N`), which is not a framed message.
pub async fn RawConn::read_byte(self : RawConn) -> Byte {
  let b = self.stream.read_exactly(1)
  b[0]
}

///|
/// Enable or disable protocol tracing.
pub fn RawConn::set_trace(self : RawConn, on : Bool) -> Unit {
  self.trace = on
}

// ---------------------------------------------------------------------------
// Cancel request
// ---------------------------------------------------------------------------

///|
/// Cancel request magic number (different from SSL request).
const CANCEL_REQUEST_CODE : Int = 80877102

///|
/// Send a cancel request to the server via a new TCP connection.
/// Best-effort — all errors are silently ignored.
async fn cancel_request(
  host : String,
  port : Int,
  backend_pid : Int,
  secret_key : Int,
) -> Unit {
  let addr = @socket.Addr::resolve(host, port~) catch { _ => return }
  let tcp = @socket.Tcp::connect(addr) catch { _ => return }
  let buf = BytesMut::new()
  buf.append_int_be(16)
  buf.append_int_be(CANCEL_REQUEST_CODE)
  buf.append_int_be(backend_pid)
  buf.append_int_be(secret_key)
  tcp.write(buf.to_bytes())
  tcp.close()
}

// ---------------------------------------------------------------------------
// Extended query protocol
// ---------------------------------------------------------------------------

///|
/// Create a prepared statement.
///
/// Sends `Parse` + `Describe(S)` + `Sync`, then reads responses until
/// `ReadyForQuery`.  Returns a `StatementDescription` with the inferred
/// parameter OIDs and result-column layout.
///
/// If `name` is empty the unnamed statement is used, which is overwritten
/// by the next `Parse` on that connection.
///
/// `param_types` — OID for each parameter; `0` = leave type unspecified.
///   An empty array means "infer all".
pub async fn RawConn::prepare(
  self : RawConn,
  name : String,
  sql : String,
  param_types : Array[Int],
) -> StatementDescription raise WireError {
  self.lock()

  self.send(Parse::{ name, query: sql, param_types })
  self.send(Describe::{ variant: b'S', name })
  self.send(Sync::{  })

  let mut param_oids : Array[Int] = []
  let mut fields : Array[FieldDescription] = []

  for ;; {
    let msg = self.receive()
    match msg {
      ParseComplete(_) => ()
      ParameterDescription(pd) => param_oids = pd.param_types
      RowDescription(rd) => fields = rd.columns
      NoData(_) => ()
      ErrorResponse(e) => {
        let msg = e.message().unwrap_or("unknown")
        self.end_query()
        raise WireError::PgServer(msg)
      }
      ReadyForQuery(rfq) => {
        self.tx_status = rfq.status
        break
      }
      NoticeResponse(_) => continue
      _ => continue
    }
  }

  self.unlock()
  StatementDescription::{ name, sql, param_oids, fields }
}

///|
/// Bind a portal to a prepared statement, supplying concrete parameter values.
///
/// `portal`    — portal name (empty string = unnamed).
/// `statement` — source prepared statement name (empty = unnamed).
/// `params` — parameter values (`None` = SQL NULL).
/// `param_formats` — `0` = text, `1` = binary.
///   Empty array = all text; single element = applies to all.
/// `result_formats` — `0` = text, `1` = binary.
///   Same convention as `param_formats`.
///
/// The server responds with `BindComplete`.  Call `describe_portal`
/// afterwards to get the result-column descriptions.
pub async fn RawConn::bind(
  self : RawConn,
  portal : String,
  statement : String,
  params : Array[Bytes?],
  param_formats : Array[Int],
  result_formats : Array[Int],
) -> Unit raise WireError {
  self.send(Bind::{ portal, statement, params, param_formats, result_formats })
  self.flush()
  match self.receive() {
    BindComplete(_) => ()
    ErrorResponse(e) =>
      raise WireError::PgServer(e.message().unwrap_or("unknown"))
    msg =>
      raise WireError::InvalidMessage(
        "expected BindComplete, got \{msg.describe()}",
      )
  }
}

///|
/// Describe a portal to learn its result-column layout.
///
/// Returns the `columns` array suitable for passing to `execute`.
/// Returns an empty array when the portal produces no result set
/// (e.g. `INSERT` / `UPDATE` / `DELETE`).
pub async fn RawConn::describe_portal(
  self : RawConn,
  portal : String,
) -> Array[FieldDescription] raise WireError {
  self.send(Describe::{ variant: b'P', name: portal })
  self.flush()
  match self.receive() {
    RowDescription(rd) => rd.columns
    NoData(_) => []
    ErrorResponse(e) =>
      raise WireError::PgServer(e.message().unwrap_or("unknown"))
    msg =>
      raise WireError::InvalidMessage(
        "expected RowDescription or NoData, got \{msg.describe()}",
      )
  }
}

///|
/// Describe a prepared statement to learn its parameter types.
///
/// Returns integer OIDs for each parameter placeholder.  Useful when
/// the statement was prepared with `param_types` set to `[]` or `[0]`.
pub async fn RawConn::describe_statement(
  self : RawConn,
  name : String,
) -> Array[Int] raise WireError {
  self.send(Describe::{ variant: b'S', name })
  self.flush()
  match self.receive() {
    ParameterDescription(pd) => pd.param_types
    ErrorResponse(e) =>
      raise WireError::PgServer(e.message().unwrap_or("unknown"))
    msg =>
      raise WireError::InvalidMessage(
        "expected ParameterDescription, got \{msg.describe()}",
      )
  }
}

///|
/// Execute a portal and return a `ResultReader` for pulling rows.
///
/// Sends `Execute` followed by `Sync` so that `ReadyForQuery` follows
/// naturally after the last row.  The returned `ResultReader` streams
/// `DataRow` messages and drains through `ReadyForQuery` on close.
///
/// `columns` — obtained from a prior `describe_portal` call.
/// `max_rows` — row limit; `0` = unlimited.
pub async fn RawConn::execute(
  self : RawConn,
  portal : String,
  columns : Array[FieldDescription],
  max_rows : Int,
) -> ResultReader raise WireError {
  self.lock()
  self.send(Execute::{ portal, max_rows })
  self.send(Sync::{  })
  ResultReader::{
    conn: self,
    columns,
    row_values: None,
    closed: false,
    tag: None,
  }
}

// ---------------------------------------------------------------------------
// Extended query — lifecycle management
// ---------------------------------------------------------------------------

///|
/// Close a prepared statement.
pub async fn RawConn::close_statement(
  self : RawConn,
  name : String,
) -> Unit raise WireError {
  self.send(Close::{ variant: b'S', name })
  self.flush()
  match self.receive() {
    CloseComplete(_) => ()
    ErrorResponse(e) =>
      raise WireError::PgServer(e.message().unwrap_or("unknown"))
    msg =>
      raise WireError::InvalidMessage(
        "expected CloseComplete, got \{msg.describe()}",
      )
  }
}

///|
/// Close a portal.
pub async fn RawConn::close_portal(
  self : RawConn,
  name : String,
) -> Unit raise WireError {
  self.send(Close::{ variant: b'P', name })
  self.flush()
  match self.receive() {
    CloseComplete(_) => ()
    ErrorResponse(e) =>
      raise WireError::PgServer(e.message().unwrap_or("unknown"))
    msg =>
      raise WireError::InvalidMessage(
        "expected CloseComplete, got \{msg.describe()}",
      )
  }
}

///|
/// Force the server to process all pending extended-query messages and
/// return `ReadyForQuery`.  Updates `conn.tx_status`.
pub async fn RawConn::sync(self : RawConn) -> Unit raise WireError {
  self.send(Sync::{  })
  for ;; {
    match self.receive() {
      ReadyForQuery(rfq) => {
        self.tx_status = rfq.status
        return
      }
      ErrorResponse(e) => {
        let msg = e.message().unwrap_or("unknown")
        raise WireError::PgServer(msg)
      }
      _ => continue
    }
  }
}

// ---------------------------------------------------------------------------
// Convenience: full extended-query round-trip
// ---------------------------------------------------------------------------

///|
/// Execute a parameterized SQL command via the extended query protocol.
///
/// An unnamed statement is parsed from `sql`, bound to an unnamed portal with
/// the given parameter values, and executed.  The returned `ResultReader`
/// streams rows from the server.
///
/// **Parameter conventions** (mirrors pgx `ExecParams`):
///
/// * `param_oids` — OID for each parameter value.  `0` = let the server infer.
///   Must have length `0`, `1` (applied to all), or equal to `param_values`.
///   An empty array means "infer all".
///
/// * `param_formats` — format code per parameter: `0` = text, `1` = binary.
///   Must have length `0`, `1` (applied to all), or equal to `param_values`.
///   An empty array means "all text".
///
/// * `result_formats` — format code per result column: `0` = text, `1` = binary.
///   Must have length `0`, `1` (applied to all), or equal to the number of
///   result columns.  An empty array means "all text".
///
/// * `param_values` — one element per `$n` placeholder.  `None` = SQL NULL.
///   Values must already be encoded per the corresponding format code.
///
/// The reader **must** be consumed (via `read` / `has_next`+`close`) or
/// explicitly closed before `RawConn` can be used for another query.
pub async fn RawConn::execute_params(
  self : RawConn,
  sql : String,
  param_values : Array[Bytes?],
  param_oids : Array[Int],
  param_formats : Array[Int],
  result_formats : Array[Int],
) -> ResultReader raise WireError {
  let n = param_values.length()

  // PG wire protocol uses Int16 for parameter count — reject overflow.
  guard n <= 65535 else {
    raise WireError::InvalidMessage(
      "extended protocol limited to 65535 parameters, got \{n}",
    )
  }

  // --- validate & normalise param_oids -----------------------------------
  let p_oids : Array[Int] = match param_oids.length() {
    0 => []
    1 => Array::makei(n, fn(_) { param_oids[0] })
    _ => {
      guard param_oids.length() == n else {
        raise WireError::Parse(
          "param_oids length (\{param_oids.length()}) must be 0, 1, or equal to param_values (\{n})",
        )
      }
      param_oids
    }
  }

  let p_formats : Array[Int] = expand_formats(n, param_formats)

  // result_formats are sent as-is; PG applies the single-element convention.

  self.lock()

  // --- send the pipeline --------------------------------------------------
  // Parse (unnamed statement)
  self.send(Parse::{ name: "", query: sql, param_types: p_oids })
  // Bind (unnamed statement → unnamed portal)
  self.send(Bind::{
    portal: "",
    statement: "",
    params: param_values,
    param_formats: p_formats,
    result_formats,
  })
  // Describe portal to get result-column metadata
  self.send(Describe::{ variant: b'P', name: "" })
  // Execute (all rows)
  self.send(Execute::{ portal: "", max_rows: 0 })
  // Sync — implicitly flushes all pending messages and triggers ReadyForQuery
  self.send(Sync::{  })

  // --- read pipeline responses -------------------------------------------
  // 1. ParseComplete
  match self.receive() {
    ParseComplete(_) => ()
    ErrorResponse(e) => {
      let msg = e.message().unwrap_or("unknown")
      self.end_query()
      raise WireError::PgServer(msg)
    }
    msg => {
      self.end_query()
      raise WireError::InvalidMessage(
        "expected ParseComplete, got \{msg.describe()}",
      )
    }
  }

  // 2. BindComplete
  match self.receive() {
    BindComplete(_) => ()
    ErrorResponse(e) => {
      let msg = e.message().unwrap_or("unknown")
      self.end_query()
      raise WireError::PgServer(msg)
    }
    msg => {
      self.end_query()
      raise WireError::InvalidMessage(
        "expected BindComplete, got \{msg.describe()}",
      )
    }
  }

  // 3. RowDescription | NoData (result-column layout)
  let columns = match self.receive() {
    RowDescription(rd) => rd.columns
    NoData(_) => []
    ErrorResponse(e) => {
      let msg = e.message().unwrap_or("unknown")
      self.end_query()
      raise WireError::PgServer(msg)
    }
    msg => {
      self.end_query()
      raise WireError::InvalidMessage(
        "expected RowDescription or NoData, got \{msg.describe()}",
      )
    }
  }

  // --- return reader (it will consume DataRow + CommandComplete + ReadyForQuery) ---
  ResultReader::{
    conn: self,
    columns,
    row_values: None,
    closed: false,
    tag: None,
  }
}

///|
/// Execute a named prepared statement via the extended query protocol.
///
/// Sends `Bind` (unnamed portal ← named statement) + `Describe(P)` +
/// `Execute` + `Sync`, then reads `BindComplete` + `RowDescription`/`NoData`
/// and returns a `ResultReader` for streaming rows.
///
/// `param_values` — one element per parameter placeholder. `None` = NULL.
///   Values must already be encoded per the corresponding format code.
///
/// `param_formats` — `0` = text, `1` = binary.  Length must be `0`, `1`,
///   or equal to `param_values`.
///
/// `result_formats` — `0` = text, `1` = binary.  Same convention.
///
/// Call `execute_statement` instead if you already have a
/// `StatementDescription` — it skips the `Describe` round-trip.
pub async fn RawConn::execute_prepared(
  self : RawConn,
  stmt_name : String,
  param_values : Array[Bytes?],
  param_formats : Array[Int],
  result_formats : Array[Int],
) -> ResultReader raise WireError {
  let n = param_values.length()
  guard n <= 65535 else {
    raise WireError::InvalidMessage(
      "extended protocol limited to 65535 parameters, got \{n}",
    )
  }
  let p_formats : Array[Int] = expand_formats(n, param_formats)

  self.lock()

  self.send(Bind::{
    portal: "",
    statement: stmt_name,
    params: param_values,
    param_formats: p_formats,
    result_formats,
  })
  self.send(Describe::{ variant: b'P', name: "" })
  self.send(Execute::{ portal: "", max_rows: 0 })
  self.send(Sync::{  })

  // 1. BindComplete
  match self.receive() {
    BindComplete(_) => ()
    ErrorResponse(e) => {
      let msg = e.message().unwrap_or("unknown")
      self.end_query()
      raise WireError::PgServer(msg)
    }
    msg => {
      self.end_query()
      raise WireError::InvalidMessage(
        "expected BindComplete, got \{msg.describe()}",
      )
    }
  }

  // 2. RowDescription | NoData
  let columns = match self.receive() {
    RowDescription(rd) => rd.columns
    NoData(_) => []
    ErrorResponse(e) => {
      let msg = e.message().unwrap_or("unknown")
      self.end_query()
      raise WireError::PgServer(msg)
    }
    msg => {
      self.end_query()
      raise WireError::InvalidMessage(
        "expected RowDescription or NoData, got \{msg.describe()}",
      )
    }
  }

  ResultReader::{
    conn: self,
    columns,
    row_values: None,
    closed: false,
    tag: None,
  }
}

///|
/// Execute a prepared statement using its `StatementDescription`.
///
/// Unlike `execute_prepared`, this does **not** send a `Describe` message
/// because the result-column layout is already known from the
/// `StatementDescription`.  Saves one network round-trip.
///
/// `param_values` — one element per parameter placeholder. `None` = NULL.
///   Values must already be encoded per the corresponding format code.
///
/// `param_formats` — `0` = text, `1` = binary.  Length must be `0`, `1`,
///   or equal to `param_values`.
///
/// `result_formats` — `0` = text, `1` = binary.  Same convention.
pub async fn RawConn::execute_statement(
  self : RawConn,
  stmt_desc : StatementDescription,
  param_values : Array[Bytes?],
  param_formats : Array[Int],
  result_formats : Array[Int],
) -> ResultReader raise WireError {
  let n = param_values.length()
  guard n <= 65535 else {
    raise WireError::InvalidMessage(
      "extended protocol limited to 65535 parameters, got \{n}",
    )
  }
  let p_formats : Array[Int] = expand_formats(n, param_formats)

  self.lock()

  self.send(Bind::{
    portal: "",
    statement: stmt_desc.name,
    params: param_values,
    param_formats: p_formats,
    result_formats,
  })
  self.send(Execute::{ portal: "", max_rows: 0 })
  self.send(Sync::{  })

  // Read BindComplete
  match self.receive() {
    BindComplete(_) => ()
    ErrorResponse(e) => {
      let msg = e.message().unwrap_or("unknown")
      self.end_query()
      raise WireError::PgServer(msg)
    }
    msg => {
      self.end_query()
      raise WireError::InvalidMessage(
        "expected BindComplete, got \{msg.describe()}",
      )
    }
  }

  // Columns already known — no Describe needed.
  ResultReader::{
    conn: self,
    columns: stmt_desc.fields,
    row_values: None,
    closed: false,
    tag: None,
  }
}

///|
/// Normalise format codes: `[]` → all-0, `[x]` → broadcast to `n`.
/// Rejects lengths other than 0, 1, or `n`.
fn expand_formats(n : Int, formats : Array[Int]) -> Array[Int] raise WireError {
  match formats.length() {
    0 => Array::makei(n, fn(_) { 0 })
    1 => Array::makei(n, fn(_) { formats[0] })
    _ => {
      guard formats.length() == n else {
        raise WireError::Parse(
          "format length (\{formats.length()}) must be 0, 1, or equal to param count (\{n})",
        )
      }
      formats
    }
  }
}
