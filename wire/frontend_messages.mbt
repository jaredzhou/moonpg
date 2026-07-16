///|
/// Frontend (client → server) message types for the PostgreSQL wire protocol.
///
/// Every message implements the `Message` trait and knows how to encode itself
/// to wire-format `Bytes` and decode itself from wire-format `Bytes`.

// ---------------------------------------------------------------------------
// Message trait
// ---------------------------------------------------------------------------

///|
/// Trait for PostgreSQL wire-protocol messages.
///
/// Every message knows how to encode itself to wire-format `Bytes` and
/// decode itself from wire-format `Bytes`.
pub(open) trait Message {
  fn encode(Self) -> Bytes raise WireError
  fn decode(BytesView) -> Self raise WireError
  fn describe(Self) -> String
}

// ---------------------------------------------------------------------------
// Shared helper types
// ---------------------------------------------------------------------------

///|
/// A key-value parameter pair used in `StartupMessage`.
pub(all) struct ConnParam {
  key : String
  value : String
}

///|
/// A single typed field in an `ErrorResponse` or `NoticeResponse`.
pub(all) struct ErrorField {
  field_type : Byte
  value : String
} derive(Debug)

// ---------------------------------------------------------------------------
// PasswordMessage ('p')
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `PasswordMessage` (F).
pub(all) struct PasswordMessage {
  password : String
}

///|
pub impl Message for PasswordMessage with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_PASSWORD)
  buf.append_int_be(0) // placeholder
  buf.append_string_null(self.password)
  let total = buf.len() - 1
  buf.set_int_be(1, total) // patch
  buf.to_bytes()
}

///|
pub impl Message for PasswordMessage with fn decode(payload) -> PasswordMessage raise WireError {
  let (password, _) = read_cstring(payload[:])
  { password, }
}

///|
pub impl Message for PasswordMessage with fn describe(_self) -> String {
  "PasswordMessage"
}

// ---------------------------------------------------------------------------
// Query ('Q')
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `Query` (F).
pub(all) struct Query {
  sql : String
}

///|
pub impl Message for Query with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_QUERY)
  buf.append_int_be(0) // placeholder
  buf.append_string_null(self.sql)
  let total = buf.len() - 1
  buf.set_int_be(1, total)
  buf.to_bytes()
}

///|
pub impl Message for Query with fn decode(payload) -> Query raise WireError {
  let (sql, _) = read_cstring(payload[:])
  { sql, }
}

///|
pub impl Message for Query with fn describe(_self) -> String {
  "Query"
}

// ---------------------------------------------------------------------------
// SASLInitialResponse ('p')
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `SASLInitialResponse` (F).
pub(all) struct SASLInitialResponse {
  mechanism : String
  initial_response : Bytes
}

///|
pub impl Message for SASLInitialResponse with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_PASSWORD)
  buf.append_int_be(0) // placeholder
  buf.append_string_null(self.mechanism)
  buf.append_int_be(self.initial_response.length())
  buf.append_bytes(self.initial_response)
  let total = buf.len() - 1
  buf.set_int_be(1, total)
  buf.to_bytes()
}

///|
pub impl Message for SASLInitialResponse with fn decode(payload) -> SASLInitialResponse raise WireError {
  let (mechanism, rest) = read_cstring(payload[:])
  guard rest is [i32be(resp_len), .. data] else {
    raise WireError::InvalidMessage(
      "SASLInitialResponse: missing response length",
    )
  }
  let initial_response = if resp_len > 0 {
    guard data.length() >= resp_len else {
      raise WireError::InvalidMessage(
        "SASLInitialResponse: response data truncated",
      )
    }
    data[0:resp_len].to_owned()
  } else {
    Bytes::default()
  }
  { mechanism, initial_response }
}

///|
pub impl Message for SASLInitialResponse with fn describe(self) -> String {
  "SASLInitialResponse(mech=\{self.mechanism})"
}

// ---------------------------------------------------------------------------
// SASLResponse ('p')
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `SASLResponse` (F).
pub(all) struct SASLResponse {
  data : Bytes
}

///|
pub impl Message for SASLResponse with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_PASSWORD)
  buf.append_int_be(0)
  buf.append_bytes(self.data)
  buf.set_int_be(1, buf.len() - 1)
  buf.to_bytes()
}

///|
pub impl Message for SASLResponse with fn decode(payload) -> SASLResponse raise WireError {
  { data: payload.to_owned() }
}

///|
pub impl Message for SASLResponse with fn describe(self) -> String {
  "SASLResponse(\{self.data.length()} bytes)"
}

// ---------------------------------------------------------------------------
// SSLRequest (no type byte)
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `SSLRequest` (F).
pub(all) struct SSLRequest {}

///|
pub impl Message for SSLRequest with fn encode(_self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_int_be(8)
  buf.append_int_be(SSL_REQUEST_CODE)
  buf.to_bytes()
}

///|
pub impl Message for SSLRequest with fn decode(payload) -> SSLRequest raise WireError {
  guard payload is [i32be(code)] else {
    raise WireError::InvalidMessage("invalid SSLRequest payload")
  }
  guard code == SSL_REQUEST_CODE else {
    raise WireError::InvalidMessage("not an SSL request: \{code}")
  }
  SSLRequest::{  }
}

///|
pub impl Message for SSLRequest with fn describe(_self) -> String {
  "SSLRequest"
}

// ---------------------------------------------------------------------------
// StartupMessage (no type byte)
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `StartupMessage` (F).
pub(all) struct StartupMessage {
  version : ProtocolVersion
  params : Array[ConnParam]
}

///|
pub impl Message for StartupMessage with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_int_be(0) // placeholder
  buf.append_int_be(self.version.to_int32())
  for i = 0; i < self.params.length(); i = i + 1 {
    let pair = self.params[i]
    buf.append_string_null(pair.key)
    buf.append_string_null(pair.value)
  }
  buf.append_byte(b'\x00')
  let total = buf.len()
  buf.set_int_be(0, total)
  buf.to_bytes()
}

///|
pub impl Message for StartupMessage with fn decode(payload) -> StartupMessage raise WireError {
  guard payload is [i32be(version_code), .. rest] else {
    raise WireError::InvalidMessage("StartupMessage: too short")
  }
  let version = match version_code {
    196608 => V3_0
    196610 => V3_2
    n => raise WireError::InvalidMessage("unknown protocol version: \{n}")
  }
  let params : Array[ConnParam] = []
  for rest = rest {
    match rest {
      [b'\x00', ..] => break
      _ => {
        let (key, r1) = read_cstring(rest[:])
        let (value, r2) = read_cstring(r1)
        params.push(ConnParam::{ key, value })
        continue r2
      }
    }
  }
  { version, params }
}

///|
pub impl Message for StartupMessage with fn describe(self) -> String {
  let mut db = "?"
  for i = 0; i < self.params.length(); i = i + 1 {
    if self.params[i].key == "database" {
      db = self.params[i].value
      break
    }
  }
  "StartupMessage(db=\{db})"
}

// ---------------------------------------------------------------------------
// Terminate ('X')
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `Terminate` (F).
pub(all) struct Terminate {}

///|
pub impl Message for Terminate with fn encode(_self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_TERMINATE)
  buf.append_int_be(4)
  buf.to_bytes()
}

///|
pub impl Message for Terminate with fn decode(_payload) -> Terminate raise WireError {
  Terminate::{  }
}

///|
pub impl Message for Terminate with fn describe(_self) -> String {
  "Terminate"
}

// ---------------------------------------------------------------------------
// Parse ('P') — Extended Query
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `Parse` (F) — creates a prepared statement.
pub(all) struct Parse {
  /// Statement name (empty string = unnamed).
  name : String
  /// SQL query string (single statement only).
  query : String
  /// Parameter type OIDs; 0 = unspecified, fewer than $n = remaining unspecified.
  param_types : Array[Int]
}

///|
pub impl Message for Parse with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_PARSE)
  buf.append_int_be(0) // placeholder
  buf.append_string_null(self.name)
  buf.append_string_null(self.query)
  let n = self.param_types.length()
  buf.append_byte(((n >> 8) & 0xFF).to_byte())
  buf.append_byte((n & 0xFF).to_byte())
  for i = 0; i < n; i = i + 1 {
    buf.append_int_be(self.param_types[i])
  }
  let total = buf.len() - 1
  buf.set_int_be(1, total)
  buf.to_bytes()
}

///|
pub impl Message for Parse with fn decode(payload) -> Parse raise WireError {
  let (name, r1) = read_cstring(payload[:])
  let (query, r2) = read_cstring(r1)
  guard r2 is [i16be(n), .. r3] else {
    raise WireError::InvalidMessage("Parse: truncated param count")
  }
  let param_types : Array[Int] = []
  for r3 = r3 {
    if param_types.length() >= n {
      break
    }
    guard r3 is [i32be(oid), .. rest] else {
      raise WireError::InvalidMessage("Parse: truncated param OID")
    }
    param_types.push(oid)
    continue rest
  }
  { name, query, param_types }
}

///|
pub impl Message for Parse with fn describe(self) -> String {
  "Parse(\{self.name}=>\{self.query})"
}

// ---------------------------------------------------------------------------
// Bind ('B') — Extended Query
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `Bind` (F) — creates a portal from a prepared statement.
pub(all) struct Bind {
  /// Destination portal name (empty string = unnamed).
  portal : String
  /// Source prepared statement name (empty string = unnamed).
  statement : String
  /// Parameter format codes: 0 = text, 1 = binary.
  ///   Empty array = all text, single value = applies to all.
  param_formats : Array[Int]
  /// Parameter values. `None` = NULL. Must match statement's param count.
  params : Array[Bytes?]
  /// Result-column format codes: 0 = text, 1 = binary.
  ///   Empty array = all text, single value = applies to all.
  result_formats : Array[Int]
}

///|
pub impl Message for Bind with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_BIND)
  buf.append_int_be(0) // placeholder
  buf.append_string_null(self.portal)
  buf.append_string_null(self.statement)
  // parameter format codes
  let npf = self.param_formats.length()
  buf.append_byte(((npf >> 8) & 0xFF).to_byte())
  buf.append_byte((npf & 0xFF).to_byte())
  for i = 0; i < npf; i = i + 1 {
    let v = self.param_formats[i]
    buf.append_byte(((v >> 8) & 0xFF).to_byte())
    buf.append_byte((v & 0xFF).to_byte())
  }
  // parameter values
  let np = self.params.length()
  buf.append_byte(((np >> 8) & 0xFF).to_byte())
  buf.append_byte((np & 0xFF).to_byte())
  for i = 0; i < self.params.length(); i = i + 1 {
    match self.params[i] {
      None => buf.append_int_be(-1)
      Some(v) => {
        buf.append_int_be(v.length())
        buf.append_bytes(v)
      }
    }
  }
  // result-column format codes
  let nrf = self.result_formats.length()
  buf.append_byte(((nrf >> 8) & 0xFF).to_byte())
  buf.append_byte((nrf & 0xFF).to_byte())
  for i = 0; i < nrf; i = i + 1 {
    let v = self.result_formats[i]
    buf.append_byte(((v >> 8) & 0xFF).to_byte())
    buf.append_byte((v & 0xFF).to_byte())
  }
  let total = buf.len() - 1
  buf.set_int_be(1, total)
  buf.to_bytes()
}

///|
pub impl Message for Bind with fn decode(payload) -> Bind raise WireError {
  let (portal, r1) = read_cstring(payload[:])
  let (statement, r2) = read_cstring(r1)
  // parameter format codes
  guard r2 is [i16be(n_pf), .. r3] else {
    raise WireError::InvalidMessage("Bind: truncated param format count")
  }
  let param_formats : Array[Int] = []
  for r3 = r3 {
    if param_formats.length() >= n_pf {
      break
    }
    guard r3 is [i16be(f), .. rest] else {
      raise WireError::InvalidMessage("Bind: truncated param format")
    }
    param_formats.push(f)
    continue rest
  }
  // parameter values
  guard r3 is [i16be(n_p), .. r4] else {
    raise WireError::InvalidMessage("Bind: truncated param count")
  }
  let params : Array[Bytes?] = []
  for r4 = r4 {
    if params.length() >= n_p {
      break
    }
    guard r4 is [i32be(len), .. r5] else {
      raise WireError::InvalidMessage("Bind: truncated param length")
    }
    if len < 0 {
      params.push(None)
      continue r5
    } else {
      guard r5.length() >= len else {
        raise WireError::InvalidMessage("Bind: truncated param value")
      }
      params.push(Some(r5[0:len].to_owned()))
      continue r5[len:]
    }
  }
  guard r4 is [i16be(n_rf), .. r6] else {
    raise WireError::InvalidMessage("Bind: truncated result format count")
  }
  let result_formats : Array[Int] = []
  for r6 = r6 {
    if result_formats.length() >= n_rf {
      break
    }
    guard r6 is [i16be(f), .. rest] else {
      raise WireError::InvalidMessage("Bind: truncated result format")
    }
    result_formats.push(f)
    continue rest
  }
  { portal, statement, param_formats, params, result_formats }
}

///|
pub impl Message for Bind with fn describe(self) -> String {
  "Bind(portal=\{self.portal}, stmt=\{self.statement}, params=\{self.params.length()})"
}

// ---------------------------------------------------------------------------
// Describe ('D') — Extended Query
// ---------------------------------------------------------------------------

///|
/// Describe a prepared statement (`b'S'`) or portal (`b'P'`).
pub(all) struct Describe {
  /// `b'S'` for statement, `b'P'` for portal.
  variant : Byte
  /// Name of the statement or portal (empty string = unnamed).
  name : String
}

///|
pub impl Message for Describe with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_DESCRIBE)
  buf.append_int_be(0) // placeholder
  buf.append_byte(self.variant)
  buf.append_string_null(self.name)
  let total = buf.len() - 1
  buf.set_int_be(1, total)
  buf.to_bytes()
}

///|
pub impl Message for Describe with fn decode(payload) -> Describe raise WireError {
  guard payload is [variant, .. rest] else {
    raise WireError::InvalidMessage("Describe: truncated")
  }
  let (name, _) = read_cstring(rest)
  { variant, name }
}

///|
pub impl Message for Describe with fn describe(self) -> String {
  let target = if self.variant == b'S' { "statement" } else { "portal" }
  "Describe(\{target}=\{self.name})"
}

// ---------------------------------------------------------------------------
// Execute ('E') — Extended Query
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `Execute` (F) — runs a portal.
pub(all) struct Execute {
  /// Portal name (empty string = unnamed).
  portal : String
  /// Max rows to return; 0 = no limit.
  max_rows : Int
}

///|
pub impl Message for Execute with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_EXECUTE)
  buf.append_int_be(0) // placeholder
  buf.append_string_null(self.portal)
  buf.append_int_be(self.max_rows)
  let total = buf.len() - 1
  buf.set_int_be(1, total)
  buf.to_bytes()
}

///|
pub impl Message for Execute with fn decode(payload) -> Execute raise WireError {
  let (portal, rest) = read_cstring(payload[:])
  guard rest is [i32be(max_rows)] else {
    raise WireError::InvalidMessage("Execute: truncated max_rows")
  }
  { portal, max_rows }
}

///|
pub impl Message for Execute with fn describe(self) -> String {
  "Execute(portal=\{self.portal}, max_rows=\{self.max_rows})"
}

// ---------------------------------------------------------------------------
// Close ('C') — Extended Query
// ---------------------------------------------------------------------------

///|
/// Close a prepared statement (`b'S'`) or portal (`b'P'`).
pub(all) struct Close {
  /// `b'S'` for statement, `b'P'` for portal.
  variant : Byte
  /// Name of the statement or portal (empty string = unnamed).
  name : String
}

///|
pub impl Message for Close with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_CLOSE)
  buf.append_int_be(0) // placeholder
  buf.append_byte(self.variant)
  buf.append_string_null(self.name)
  let total = buf.len() - 1
  buf.set_int_be(1, total)
  buf.to_bytes()
}

///|
pub impl Message for Close with fn decode(payload) -> Close raise WireError {
  guard payload is [variant, .. rest] else {
    raise WireError::InvalidMessage("Close: truncated")
  }
  let (name, _) = read_cstring(rest)
  { variant, name }
}

///|
pub impl Message for Close with fn describe(self) -> String {
  let target = if self.variant == b'S' { "statement" } else { "portal" }
  "Close(\{target}=\{self.name})"
}

// ---------------------------------------------------------------------------
// Sync ('S') — Extended Query
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `Sync` (F) — commit point; server responds with `ReadyForQuery`.
pub(all) struct Sync {}

///|
pub impl Message for Sync with fn encode(_self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_SYNC)
  buf.append_int_be(4)
  buf.to_bytes()
}

///|
pub impl Message for Sync with fn decode(_payload) -> Sync raise WireError {
  Sync::{  }
}

///|
pub impl Message for Sync with fn describe(_self) -> String {
  "Sync"
}

// ---------------------------------------------------------------------------
// Flush ('H') — Extended Query
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `Flush` (F) — flush server output buffer without Sync's
/// transaction effects.
pub(all) struct Flush {}

///|
pub impl Message for Flush with fn encode(_self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_FLUSH)
  buf.append_int_be(4)
  buf.to_bytes()
}

///|
pub impl Message for Flush with fn decode(_payload) -> Flush raise WireError {
  Flush::{  }
}

///|
pub impl Message for Flush with fn describe(_self) -> String {
  "Flush"
}

// ---------------------------------------------------------------------------
// COPY protocol — frontend messages
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `CopyData` (F) — data row for `COPY ... FROM STDIN`.
pub(all) struct CopyData {
  data : Bytes
}

///|
pub impl Message for CopyData with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_COPY_DATA)
  buf.append_int_be(4 + self.data.length())
  buf.append_bytes(self.data)
  buf.to_bytes()
}

///|
pub impl Message for CopyData with fn decode(_payload) -> CopyData raise WireError {
  raise WireError::InvalidMessage("CopyData decode not implemented (frontend)")
}

///|
pub impl Message for CopyData with fn describe(_self) -> String {
  "CopyData"
}

///|
/// PostgreSQL `CopyDone` (F) — signal end of COPY data.
pub(all) struct CopyDone {}

///|
pub impl Message for CopyDone with fn encode(_self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_COPY_DONE)
  buf.append_int_be(4)
  buf.to_bytes()
}

///|
pub impl Message for CopyDone with fn decode(_payload) -> CopyDone raise WireError {
  CopyDone::{  }
}

///|
pub impl Message for CopyDone with fn describe(_self) -> String {
  "CopyDone"
}

///|
/// PostgreSQL `CopyFail` (F) — abort COPY with an error message.
pub(all) struct CopyFail {
  message : String
}

///|
pub impl Message for CopyFail with fn encode(self) -> Bytes {
  let msg_bytes = @utf8.encode(self.message)
  let buf = BytesMut::new()
  buf.append_byte(MSG_COPY_FAIL)
  buf.append_int_be(4 + msg_bytes.length() + 1)
  buf.append_bytes(msg_bytes)
  buf.append_byte(b'\x00')
  buf.to_bytes()
}

///|
pub impl Message for CopyFail with fn decode(_payload) -> CopyFail raise WireError {
  raise WireError::InvalidMessage("CopyFail decode not implemented (frontend)")
}

///|
pub impl Message for CopyFail with fn describe(_self) -> String {
  "CopyFail"
}
