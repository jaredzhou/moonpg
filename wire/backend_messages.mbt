///|
/// Backend (server → client) message types for the PostgreSQL wire protocol.
///
/// `BackendMessage` is the tagged union dispatched on the message type byte.

// ---------------------------------------------------------------------------
// Supporting types
// ---------------------------------------------------------------------------

///|
/// Per-field metadata carried in a `RowDescription` message.
pub struct FieldDescription {
  name : String
  table_oid : Int
  attr_num : Int
  type_oid : Int
  typlen : Int
  typmod : Int
  format : Int // 0 = text, 1 = binary
}

///|
/// Return the human-readable type name for this column (e.g. `"int4"`, `"text"`).
/// Looks up `type_oid` in the built-in OID map; returns `"unknown"` for
/// unrecognised OIDs.  No database round-trip.
pub fn FieldDescription::type_name(self : FieldDescription) -> String {
  oid_to_name(self.type_oid)
}

///|
/// Describes a prepared statement: its parameter OIDs and result-column
/// layout (if the statement returns rows).
pub struct StatementDescription {
  /// Statement name (empty = unnamed).
  name : String
  /// The SQL text that was parsed.
  sql : String
  /// OID for each parameter placeholder. `[]` = no parameters.
  param_oids : Array[Int]
  /// Result-column descriptions. `[]` = no result set (e.g. INSERT).
  fields : Array[FieldDescription]
}

///|
/// Parsed command-completion tag from `CommandComplete`.
///
/// PostgreSQL returns tags like `"SELECT 1"`, `"INSERT 0 1"`, `"DELETE 5"`.
pub struct CommandTag {
  tag : String
}

///|
pub impl Show for CommandTag with fn output(self, logger) {
  logger.write_string(self.tag)
}

///|
pub fn CommandTag::new(tag : String) -> CommandTag {
  { tag, }
}

///|
/// The raw tag string as sent by the server.
pub fn CommandTag::raw(self : CommandTag) -> String {
  self.tag
}

///|
/// The SQL command word, e.g. `"SELECT"`, `"INSERT"`, `"DELETE"`.
pub fn CommandTag::command(self : CommandTag) -> String {
  match self.tag.find(" ") {
    Some(i) => self.tag[0:i].to_owned()
    None => self.tag
  }
}

///|
/// Number of rows affected, if the tag includes a row count.
///
/// For `SELECT 1` returns `Some(1)`, for `INSERT 0 3` returns `Some(3)`,
/// for `CREATE TABLE` returns `None`.
pub fn CommandTag::rows_affected(self : CommandTag) -> Int? {
  // Tags end with a numeric row count when applicable, e.g. "SELECT 1".
  // INSERT has format "INSERT oid rows" — last token is the row count.
  let mut last = self.tag
  for part in self.tag.split(" ") {
    last = part.to_owned()
  }
  let n = @string.parse_int(last) catch { _ => return None }
  Some(n)
}

// ---------------------------------------------------------------------------
// BackendMessage — tagged union of all backend messages
// ---------------------------------------------------------------------------

///|
/// Tagged union of all backend (server → client) messages.
///
/// Each variant wraps a concrete message struct that implements `Message`.
pub(all) enum BackendMessage {
  AuthenticationOk(AuthenticationOk)
  AuthenticationCleartextPassword(AuthenticationCleartextPassword)
  AuthenticationMD5Password(AuthenticationMD5Password)
  AuthenticationSASL(AuthenticationSASL)
  AuthenticationSASLContinue(AuthenticationSASLContinue)
  AuthenticationSASLFinal(AuthenticationSASLFinal)
  BackendKeyData(BackendKeyData)
  ReadyForQuery(ReadyForQuery)
  ParameterStatus(ParameterStatus)
  ErrorResponse(ErrorResponse)
  NoticeResponse(NoticeResponse)
  RowDescription(RowDescription)
  DataRow(DataRow)
  CommandComplete(CommandComplete)
  EmptyQueryResponse(EmptyQueryResponse)
  ParseComplete(ParseComplete)
  BindComplete(BindComplete)
  CloseComplete(CloseComplete)
  ParameterDescription(ParameterDescription)
  NoData(NoData)
  PortalSuspended(PortalSuspended)
  CopyInResponse(CopyInResponse)
  CopyOutResponse(CopyOutResponse)
  CopyBothResponse(CopyBothResponse)
  CopyData(CopyData)
  CopyDone(CopyDone)
  NotificationResponse(NotificationResponse)
  NegotiateProtocolVersion(NegotiateProtocolVersion)
  // Catch-all for messages not yet implemented
  Unknown(Byte, BytesView)
}

///|
pub fn BackendMessage::describe(self : BackendMessage) -> String {
  match self {
    AuthenticationOk(m) => m.describe()
    AuthenticationCleartextPassword(m) => m.describe()
    AuthenticationMD5Password(m) => m.describe()
    AuthenticationSASL(m) => m.describe()
    AuthenticationSASLContinue(m) => m.describe()
    AuthenticationSASLFinal(m) => m.describe()
    BackendKeyData(m) => m.describe()
    ReadyForQuery(m) => m.describe()
    ParameterStatus(m) => m.describe()
    ErrorResponse(m) => m.describe()
    NoticeResponse(m) => m.describe()
    RowDescription(m) => m.describe()
    DataRow(m) => m.describe()
    CommandComplete(m) => m.describe()
    EmptyQueryResponse(m) => m.describe()
    ParseComplete(m) => m.describe()
    BindComplete(m) => m.describe()
    CloseComplete(m) => m.describe()
    ParameterDescription(m) => m.describe()
    NoData(m) => m.describe()
    PortalSuspended(m) => m.describe()
    CopyInResponse(m) => m.describe()
    CopyOutResponse(m) => m.describe()
    CopyBothResponse(m) => m.describe()
    CopyData(m) => m.describe()
    CopyDone(m) => m.describe()
    NotificationResponse(m) => m.describe()
    NegotiateProtocolVersion(m) => m.describe()
    Unknown(b, _) => "Unknown(type=\{b.to_int()})"
  }
}

// ---------------------------------------------------------------------------
// AuthenticationCleartextPassword ('R'/3)
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `AuthenticationCleartextPassword` (B).
pub(all) struct AuthenticationCleartextPassword {}

///|
pub impl Message for AuthenticationCleartextPassword with fn encode(_self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_AUTHENTICATION)
  buf.append_int_be(8)
  buf.append_int_be(3)
  buf.to_bytes()
}

///|
pub impl Message for AuthenticationCleartextPassword with fn decode(_payload) -> AuthenticationCleartextPassword raise WireError {
  AuthenticationCleartextPassword::{  }
}

///|
pub impl Message for AuthenticationCleartextPassword with fn describe(_self) -> String {
  "AuthenticationCleartextPassword"
}

// ---------------------------------------------------------------------------
// AuthenticationMD5Password ('R'/5)
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `AuthenticationMD5Password` (B).
pub(all) struct AuthenticationMD5Password {
  salt : Bytes
}

///|
pub impl Message for AuthenticationMD5Password with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_AUTHENTICATION)
  buf.append_int_be(12)
  buf.append_int_be(5)
  buf.append_bytes(self.salt)
  buf.to_bytes()
}

///|
pub impl Message for AuthenticationMD5Password with fn decode(payload) -> AuthenticationMD5Password raise WireError {
  { salt: payload[0:4].to_owned() }
}

///|
pub impl Message for AuthenticationMD5Password with fn describe(_self) -> String {
  "AuthenticationMD5Password"
}

// ---------------------------------------------------------------------------
// AuthenticationOk ('R'/0)
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `AuthenticationOk` (B).
pub(all) struct AuthenticationOk {}

///|
pub impl Message for AuthenticationOk with fn encode(_self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_AUTHENTICATION)
  buf.append_int_be(8)
  buf.append_int_be(0)
  buf.to_bytes()
}

///|
pub impl Message for AuthenticationOk with fn decode(_payload) -> AuthenticationOk raise WireError {
  AuthenticationOk::{  }
}

///|
pub impl Message for AuthenticationOk with fn describe(_self) -> String {
  "AuthenticationOk"
}

// ---------------------------------------------------------------------------
// AuthenticationSASL ('R'/10)
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `AuthenticationSASL` (B).
pub(all) struct AuthenticationSASL {
  mechanisms : Array[String]
}

///|
pub impl Message for AuthenticationSASL with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_AUTHENTICATION)
  buf.append_int_be(0)
  buf.append_int_be(10)
  for i = 0; i < self.mechanisms.length(); i = i + 1 {
    buf.append_string_null(self.mechanisms[i])
  }
  buf.append_byte(b'\x00')
  buf.set_int_be(1, buf.len() - 1)
  buf.to_bytes()
}

///|
pub impl Message for AuthenticationSASL with fn decode(payload) -> AuthenticationSASL raise WireError {
  let mechanisms = read_cstrings(payload[:])
  { mechanisms, }
}

///|
pub impl Message for AuthenticationSASL with fn describe(self) -> String {
  "AuthenticationSASL(\{self.mechanisms.join(", ")})"
}

// ---------------------------------------------------------------------------
// AuthenticationSASLContinue ('R'/11)
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `AuthenticationSASLContinue` (B).
pub(all) struct AuthenticationSASLContinue {
  data : Bytes
}

///|
pub impl Message for AuthenticationSASLContinue with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_AUTHENTICATION)
  buf.append_int_be(0)
  buf.append_int_be(11)
  buf.append_bytes(self.data)
  buf.set_int_be(1, buf.len() - 1)
  buf.to_bytes()
}

///|
pub impl Message for AuthenticationSASLContinue with fn decode(payload) -> AuthenticationSASLContinue raise WireError {
  { data: payload.to_owned() }
}

///|
pub impl Message for AuthenticationSASLContinue with fn describe(self) -> String {
  "AuthenticationSASLContinue(\{self.data.length()} bytes)"
}

// ---------------------------------------------------------------------------
// AuthenticationSASLFinal ('R'/12)
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `AuthenticationSASLFinal` (B).
pub(all) struct AuthenticationSASLFinal {
  data : Bytes
}

///|
pub impl Message for AuthenticationSASLFinal with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_AUTHENTICATION)
  buf.append_int_be(0)
  buf.append_int_be(12)
  buf.append_bytes(self.data)
  buf.set_int_be(1, buf.len() - 1)
  buf.to_bytes()
}

///|
pub impl Message for AuthenticationSASLFinal with fn decode(payload) -> AuthenticationSASLFinal raise WireError {
  { data: payload.to_owned() }
}

///|
pub impl Message for AuthenticationSASLFinal with fn describe(self) -> String {
  "AuthenticationSASLFinal(\{self.data.length()} bytes)"
}

// ---------------------------------------------------------------------------
// BackendKeyData ('K')
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `BackendKeyData` (B).
pub(all) struct BackendKeyData {
  pid : Int
  secret_key : Int
}

///|
pub impl Message for BackendKeyData with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_BACKEND_KEY_DATA)
  buf.append_int_be(12)
  buf.append_int_be(self.pid)
  buf.append_int_be(self.secret_key)
  buf.to_bytes()
}

///|
pub impl Message for BackendKeyData with fn decode(payload) -> BackendKeyData raise WireError {
  guard payload is [i32be(pid), .. payload] else {
    raise WireError::InvalidMessage("invalid BackendKeyData")
  }
  guard payload is [i32be(secret_key), ..] else {
    raise WireError::InvalidMessage("invalid BackendKeyData")
  }
  { pid, secret_key }
}

///|
pub impl Message for BackendKeyData with fn describe(self) -> String {
  "BackendKeyData(pid=\{self.pid})"
}

// ---------------------------------------------------------------------------
// CommandComplete ('C')
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `CommandComplete` (B).
///
/// The tag describes the completed command, e.g. `"SELECT 1"`, `"INSERT 0 1"`.
pub(all) struct CommandComplete {
  tag : CommandTag
}

///|
pub impl Message for CommandComplete with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_COMMAND_COMPLETE)
  buf.append_int_be(0) // placeholder
  buf.append_string_null(self.tag.raw())
  let total = buf.len() - 1
  buf.set_int_be(1, total)
  buf.to_bytes()
}

///|
pub impl Message for CommandComplete with fn decode(payload) -> CommandComplete raise WireError {
  let (tag, _) = read_cstring(payload[:])
  { tag: CommandTag::new(tag) }
}

///|
pub impl Message for CommandComplete with fn describe(self) -> String {
  "CommandComplete(\{self.tag})"
}

// ---------------------------------------------------------------------------
// DataRow ('D')
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `DataRow` (B).
///
/// Each column value is `Some(bytes)` for non-NULL or `None` for NULL.
/// Values are owned `Bytes` — safe to hold across message boundaries.
pub(all) struct DataRow {
  values : Array[Bytes?]
}

///|
pub impl Message for DataRow with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_DATA_ROW)
  buf.append_int_be(0) // placeholder
  let n = self.values.length()
  buf.append_byte(((n >> 8) & 0xFF).to_byte())
  buf.append_byte((n & 0xFF).to_byte())
  for i = 0; i < n; i = i + 1 {
    match self.values[i] {
      Some(v) => {
        buf.append_int_be(v.length())
        buf.append_bytes(v)
      }
      None => buf.append_int_be(-1)
    }
  }
  let total = buf.len() - 1
  buf.set_int_be(1, total)
  buf.to_bytes()
}

///|
pub impl Message for DataRow with fn decode(payload) -> DataRow raise WireError {
  guard payload is [i16be(ncols), .. rest] else {
    raise WireError::InvalidMessage("DataRow: too short for field count")
  }
  let values : Array[Bytes?] = []
  for rest0 = rest {
    if values.length() >= ncols {
      break
    }
    guard rest0 is [i32be(len), .. r1] else {
      raise WireError::InvalidMessage("DataRow: truncated column length")
    }
    if len < 0 {
      values.push(None)
      continue r1
    } else {
      guard r1.length() >= len else {
        raise WireError::InvalidMessage("DataRow: truncated column value")
      }
      values.push(Some(r1[0:len].to_owned()))
      continue r1[len:]
    }
  }
  { values, }
}

///|
pub impl Message for DataRow with fn describe(self) -> String {
  "DataRow(ncols=\{self.values.length()})"
}

// ---------------------------------------------------------------------------
// EmptyQueryResponse ('I')
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `EmptyQueryResponse` (B).
///
/// Sent when the query string is empty or whitespace-only.
pub(all) struct EmptyQueryResponse {}

///|
pub impl Message for EmptyQueryResponse with fn encode(_self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_EMPTY_QUERY)
  buf.append_int_be(4)
  buf.to_bytes()
}

///|
pub impl Message for EmptyQueryResponse with fn decode(_payload) -> EmptyQueryResponse raise WireError {
  EmptyQueryResponse::{  }
}

///|
pub impl Message for EmptyQueryResponse with fn describe(_self) -> String {
  "EmptyQueryResponse"
}

// ---------------------------------------------------------------------------
// ErrorResponse ('E')
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `ErrorResponse` (B).
pub(all) struct ErrorResponse {
  fields : Array[ErrorField]
}

///|
pub impl Message for ErrorResponse with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_ERROR_RESPONSE)
  buf.append_int_be(0)
  for i = 0; i < self.fields.length(); i = i + 1 {
    let field = self.fields[i]
    buf.append_byte(field.field_type)
    buf.append_string_null(field.value)
  }
  buf.append_byte(b'\x00')
  buf.set_int_be(1, buf.len() - 1)
  buf.to_bytes()
}

///|
pub impl Message for ErrorResponse with fn decode(payload) -> ErrorResponse raise WireError {
  let fields : Array[ErrorField] = []
  for rest = payload {
    match rest {
      [b'\x00', ..] => break
      _ => {
        let field_type = rest[0]
        let (value, next) = read_cstring(rest[1:])
        fields.push(ErrorField::{ field_type, value })
        continue next
      }
    }
  }
  { fields, }
}

///|
pub impl Message for ErrorResponse with fn describe(self) -> String {
  "ErrorResponse(\{self.message().unwrap_or("???")})"
}

///|
pub fn ErrorResponse::severity(self : ErrorResponse) -> String? {
  for i = 0; i < self.fields.length(); i = i + 1 {
    if self.fields[i].field_type == b'S' {
      return Some(self.fields[i].value)
    }
  }
  None
}

///|
pub fn ErrorResponse::code(self : ErrorResponse) -> String? {
  for i = 0; i < self.fields.length(); i = i + 1 {
    if self.fields[i].field_type == b'C' {
      return Some(self.fields[i].value)
    }
  }
  None
}

///|
pub fn ErrorResponse::message(self : ErrorResponse) -> String? {
  for i = 0; i < self.fields.length(); i = i + 1 {
    if self.fields[i].field_type == b'M' {
      return Some(self.fields[i].value)
    }
  }
  None
}

// ---------------------------------------------------------------------------
// NoticeResponse ('N')
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `NoticeResponse` (B).
pub(all) struct NoticeResponse {
  fields : Array[ErrorField]
}

///|
pub impl Message for NoticeResponse with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_NOTICE_RESPONSE)
  buf.append_int_be(0)
  for i = 0; i < self.fields.length(); i = i + 1 {
    let field = self.fields[i]
    buf.append_byte(field.field_type)
    buf.append_string_null(field.value)
  }
  buf.append_byte(b'\x00')
  buf.set_int_be(1, buf.len() - 1)
  buf.to_bytes()
}

///|
pub impl Message for NoticeResponse with fn decode(payload) -> NoticeResponse raise WireError {
  let fields : Array[ErrorField] = []
  for rest = payload {
    match rest {
      [b'\x00', ..] => break
      _ => {
        let field_type = rest[0]
        let (value, next) = read_cstring(rest[1:])
        fields.push(ErrorField::{ field_type, value })
        continue next
      }
    }
  }
  { fields, }
}

///|
pub impl Message for NoticeResponse with fn describe(self) -> String {
  "NoticeResponse(\{self.message().unwrap_or("???")})"
}

///|
pub fn NoticeResponse::message(self : NoticeResponse) -> String? {
  for i = 0; i < self.fields.length(); i = i + 1 {
    if self.fields[i].field_type == b'M' {
      return Some(self.fields[i].value)
    }
  }
  None
}

// ---------------------------------------------------------------------------
// ParameterStatus ('S')
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `ParameterStatus` (B).
pub(all) struct ParameterStatus {
  name : String
  value : String
}

///|
pub impl Message for ParameterStatus with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_PARAMETER_STATUS)
  buf.append_int_be(0)
  buf.append_string_null(self.name)
  buf.append_string_null(self.value)
  buf.set_int_be(1, buf.len() - 1)
  buf.to_bytes()
}

///|
pub impl Message for ParameterStatus with fn decode(payload) -> ParameterStatus raise WireError {
  let (name, rest) = read_cstring(payload[:])
  let (value, _) = read_cstring(rest)
  { name, value }
}

///|
pub impl Message for ParameterStatus with fn describe(self) -> String {
  "ParameterStatus(\{self.name} = \{self.value})"
}

// ---------------------------------------------------------------------------
// ReadyForQuery ('Z')
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `ReadyForQuery` (B).
pub(all) struct ReadyForQuery {
  status : TransactionStatus
}

///|
pub impl Message for ReadyForQuery with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_READY_FOR_QUERY)
  buf.append_int_be(5)
  buf.append_byte(self.status.to_byte())
  buf.to_bytes()
}

///|
pub impl Message for ReadyForQuery with fn decode(payload) -> ReadyForQuery raise WireError {
  { status: TransactionStatus::from_byte(payload[0]) }
}

///|
pub impl Message for ReadyForQuery with fn describe(self) -> String {
  "ReadyForQuery(\{self.status})"
}

// ---------------------------------------------------------------------------
// RowDescription ('T')
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `RowDescription` (B).
pub(all) struct RowDescription {
  columns : Array[FieldDescription]
}

///|
pub impl Message for RowDescription with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_ROW_DESCRIPTION)
  buf.append_int_be(0) // placeholder
  let n = self.columns.length()
  buf.append_byte(((n >> 8) & 0xFF).to_byte())
  buf.append_byte((n & 0xFF).to_byte())
  for i = 0; i < n; i = i + 1 {
    let col = self.columns[i]
    buf.append_string_null(col.name)
    buf.append_int_be(col.table_oid)
    buf.append_int_be(col.attr_num)
    buf.append_int_be(col.type_oid)
    buf.append_int_be(col.typlen)
    buf.append_int_be(col.typmod)
    buf.append_int_be(col.format)
  }
  let total = buf.len() - 1
  buf.set_int_be(1, total)
  buf.to_bytes()
}

///|
pub impl Message for RowDescription with fn decode(payload) -> RowDescription raise WireError {
  guard payload is [b1, b2, .. rest] else {
    raise WireError::InvalidMessage("RowDescription: too short for field count")
  }
  let ncols = (b1.to_int() << 8) | b2.to_int()
  let columns : Array[FieldDescription] = []
  for rest0 = rest {
    if columns.length() >= ncols {
      break
    }
    let (name, r1) = read_cstring(rest0[:])
    guard r1
      is [
        i32be(table_oid),
        i16be(attr_num),
        i32be(type_oid),
        i16be(typlen),
        i32be(typmod),
        i16be(format),
        .. r2,
      ] else {
      raise WireError::InvalidMessage(
        "RowDescription: truncated field '\{name}'",
      )
    }
    columns.push(FieldDescription::{
      name,
      table_oid,
      attr_num,
      type_oid,
      typlen,
      typmod,
      format,
    })
    continue r2
  }
  { columns, }
}

///|
pub impl Message for RowDescription with fn describe(self) -> String {
  "RowDescription(ncols=\{self.columns.length()})"
}

// ---------------------------------------------------------------------------
// ParseComplete ('1') — Extended Query
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `ParseComplete` (B).
pub(all) struct ParseComplete {}

///|
pub impl Message for ParseComplete with fn encode(_self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_PARSE_COMPLETE)
  buf.append_int_be(4)
  buf.to_bytes()
}

///|
pub impl Message for ParseComplete with fn decode(_payload) -> ParseComplete raise WireError {
  ParseComplete::{  }
}

///|
pub impl Message for ParseComplete with fn describe(_self) -> String {
  "ParseComplete"
}

// ---------------------------------------------------------------------------
// BindComplete ('2') — Extended Query
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `BindComplete` (B).
pub(all) struct BindComplete {}

///|
pub impl Message for BindComplete with fn encode(_self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_BIND_COMPLETE)
  buf.append_int_be(4)
  buf.to_bytes()
}

///|
pub impl Message for BindComplete with fn decode(_payload) -> BindComplete raise WireError {
  BindComplete::{  }
}

///|
pub impl Message for BindComplete with fn describe(_self) -> String {
  "BindComplete"
}

// ---------------------------------------------------------------------------
// CloseComplete ('3') — Extended Query
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `CloseComplete` (B).
pub(all) struct CloseComplete {}

///|
pub impl Message for CloseComplete with fn encode(_self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_CLOSE_COMPLETE)
  buf.append_int_be(4)
  buf.to_bytes()
}

///|
pub impl Message for CloseComplete with fn decode(_payload) -> CloseComplete raise WireError {
  CloseComplete::{  }
}

///|
pub impl Message for CloseComplete with fn describe(_self) -> String {
  "CloseComplete"
}

// ---------------------------------------------------------------------------
// ParameterDescription ('t') — Extended Query
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `ParameterDescription` (B).
///
/// Provides the OIDs of the parameters expected by a prepared statement.
pub(all) struct ParameterDescription {
  param_types : Array[Int]
}

///|
pub impl Message for ParameterDescription with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_PARAMETER_DESCRIPTION)
  buf.append_int_be(0) // placeholder
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
pub impl Message for ParameterDescription with fn decode(payload) -> ParameterDescription raise WireError {
  guard payload is [i16be(n), .. rest] else {
    raise WireError::InvalidMessage("ParameterDescription: truncated")
  }
  let param_types : Array[Int] = []
  for rest = rest {
    if param_types.length() >= n {
      break
    }
    guard rest is [i32be(oid), .. r1] else {
      raise WireError::InvalidMessage(
        "ParameterDescription: truncated param OID",
      )
    }
    param_types.push(oid)
    continue r1
  }
  { param_types, }
}

///|
pub impl Message for ParameterDescription with fn describe(self) -> String {
  "ParameterDescription(nparams=\{self.param_types.length()})"
}

// ---------------------------------------------------------------------------
// NoData ('n') — Extended Query
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `NoData` (B) — returned when Describe finds no result columns.
pub(all) struct NoData {}

///|
pub impl Message for NoData with fn encode(_self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_NO_DATA)
  buf.append_int_be(4)
  buf.to_bytes()
}

///|
pub impl Message for NoData with fn decode(_payload) -> NoData raise WireError {
  NoData::{  }
}

///|
pub impl Message for NoData with fn describe(_self) -> String {
  "NoData"
}

// ---------------------------------------------------------------------------
// PortalSuspended ('s') — Extended Query
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `PortalSuspended` (B) — Execute reached max_rows before
/// the portal was fully consumed.
pub(all) struct PortalSuspended {}

///|
pub impl Message for PortalSuspended with fn encode(_self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_PORTAL_SUSPENDED)
  buf.append_int_be(4)
  buf.to_bytes()
}

///|
pub impl Message for PortalSuspended with fn decode(_payload) -> PortalSuspended raise WireError {
  PortalSuspended::{  }
}

///|
pub impl Message for PortalSuspended with fn describe(_self) -> String {
  "PortalSuspended"
}

// ---------------------------------------------------------------------------
// COPY protocol — backend messages
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `CopyInResponse` (B) — server is ready to receive COPY data.
pub(all) struct CopyInResponse {
  overall_format : Int
  column_formats : Array[Int]
}

///|
pub impl Message for CopyInResponse with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_COPY_IN_RESPONSE)
  let body = BytesMut::new()
  body.append_byte(self.overall_format.to_byte())
  body.append_int_be(self.column_formats.length())
  for f in self.column_formats {
    body.append_int_be(f)
  }
  buf.append_int_be(4 + body.to_bytes().length())
  buf.append_bytes(body.to_bytes())
  buf.to_bytes()
}

///|
/// Decode `CopyInResponse`. Format: Int8 overall, Int16 ncols, Int16[ncols].
pub impl Message for CopyInResponse with fn decode(payload : BytesView) -> CopyInResponse raise WireError {
  guard payload is [overall_fmt, i16be(ncols), .. rest] else {
    raise WireError::InvalidMessage("invalid CopyInResponse")
  }
  let overall_format = overall_fmt.to_int()
  let col_formats : Array[Int] = []
  let mut r = rest
  for _ in 0..<ncols {
    guard r is [i16be(f), .. r2] else {
      raise WireError::InvalidMessage("invalid CopyInResponse column format")
    }
    col_formats.push(f)
    r = r2
  }
  CopyInResponse::{ overall_format, column_formats: col_formats }
}

///|
pub impl Message for CopyInResponse with fn describe(_self) -> String {
  "CopyInResponse"
}

///|
/// PostgreSQL `CopyOutResponse` (B) — server is sending COPY data.
pub(all) struct CopyOutResponse {
  overall_format : Int
  column_formats : Array[Int]
}

///|
pub impl Message for CopyOutResponse with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_COPY_OUT_RESPONSE)
  let body = BytesMut::new()
  body.append_byte(self.overall_format.to_byte())
  body.append_int_be(self.column_formats.length())
  for f in self.column_formats {
    body.append_int_be(f)
  }
  buf.append_int_be(4 + body.to_bytes().length())
  buf.append_bytes(body.to_bytes())
  buf.to_bytes()
}

///|
pub impl Message for CopyOutResponse with fn decode(payload : BytesView) -> CopyOutResponse raise WireError {
  guard payload is [overall_fmt, i16be(ncols), .. rest] else {
    raise WireError::InvalidMessage("invalid CopyOutResponse")
  }
  let overall_format = overall_fmt.to_int()
  let col_formats : Array[Int] = []
  let mut r = rest
  for _ in 0..<ncols {
    guard r is [i16be(f), .. r2] else {
      raise WireError::InvalidMessage("invalid CopyOutResponse column format")
    }
    col_formats.push(f)
    r = r2
  }
  CopyOutResponse::{ overall_format, column_formats: col_formats }
}

///|
pub impl Message for CopyOutResponse with fn describe(_self) -> String {
  "CopyOutResponse"
}

///|
/// PostgreSQL `CopyBothResponse` (B) — server is ready for both COPY directions.
pub(all) struct CopyBothResponse {
  overall_format : Int
  column_formats : Array[Int]
}

///|
pub impl Message for CopyBothResponse with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_COPY_BOTH_RESPONSE)
  let body = BytesMut::new()
  body.append_byte(self.overall_format.to_byte())
  body.append_int_be(self.column_formats.length())
  for f in self.column_formats {
    body.append_int_be(f)
  }
  buf.append_int_be(4 + body.to_bytes().length())
  buf.append_bytes(body.to_bytes())
  buf.to_bytes()
}

///|
pub impl Message for CopyBothResponse with fn decode(payload : BytesView) -> CopyBothResponse raise WireError {
  guard payload is [overall_fmt, i16be(ncols), .. rest] else {
    raise WireError::InvalidMessage("invalid CopyBothResponse")
  }
  let overall_format = overall_fmt.to_int()
  let col_formats : Array[Int] = []
  let mut r = rest
  for _ in 0..<ncols {
    guard r is [i16be(f), .. r2] else {
      raise WireError::InvalidMessage("invalid CopyBothResponse column format")
    }
    col_formats.push(f)
    r = r2
  }
  CopyBothResponse::{ overall_format, column_formats: col_formats }
}

///|
pub impl Message for CopyBothResponse with fn describe(_self) -> String {
  "CopyBothResponse"
}

// ---------------------------------------------------------------------------
// NotificationResponse ('A') — LISTEN / NOTIFY
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `NotificationResponse` (B).
///
/// Sent when a `NOTIFY` command is executed for a channel the client is
/// listening on (via `LISTEN`).  Can arrive at any time — even during
/// a query — so the driver queues them transparently.
pub(all) struct NotificationResponse {
  /// Process ID of the notifying backend.
  pid : Int
  /// Channel name that was notified.
  channel : String
  /// Optional payload string (empty string if no payload was given).
  payload : String
}

///|
pub impl Message for NotificationResponse with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_NOTIFICATION_RESPONSE)
  buf.append_int_be(0) // placeholder
  buf.append_int_be(self.pid)
  buf.append_string_null(self.channel)
  buf.append_string_null(self.payload)
  let total = buf.len() - 1
  buf.set_int_be(1, total)
  buf.to_bytes()
}

///|
pub impl Message for NotificationResponse with fn decode(payload : BytesView) -> NotificationResponse raise WireError {
  guard payload is [i32be(pid), .. rest] else {
    raise WireError::InvalidMessage("NotificationResponse: truncated pid")
  }
  let (channel, r1) = read_cstring(rest[:])
  let (payload_str, _) = read_cstring(r1)
  NotificationResponse::{ pid, channel, payload: payload_str }
}

///|
pub impl Message for NotificationResponse with fn describe(self) -> String {
  "NotificationResponse(ch=\{self.channel}, payload=\{self.payload})"
}

// ---------------------------------------------------------------------------
// NegotiateProtocolVersion ('v') — PG 17+ protocol negotiation
// ---------------------------------------------------------------------------

///|
/// PostgreSQL `NegotiateProtocolVersion` (B).
///
/// Sent when the client requests a protocol version newer than the server
/// supports within the same major version. The client should re-send its
/// `StartupMessage` with the version offered by the server.
pub(all) struct NegotiateProtocolVersion {
  /// The newest minor version the server supports for the requested major version.
  newest_minor_version : Int
  /// Optionally, a list of protocol options not available to the client.
  options : Array[String]
}

///|
pub impl Message for NegotiateProtocolVersion with fn encode(self) -> Bytes {
  let buf = BytesMut::new()
  buf.append_byte(MSG_NEGOTIATE_PROTOCOL_VERSION)
  buf.append_int_be(0) // placeholder
  buf.append_int_be(self.newest_minor_version)
  let n = self.options.length()
  buf.append_byte(((n >> 8) & 0xFF).to_byte())
  buf.append_byte((n & 0xFF).to_byte())
  for option in self.options {
    buf.append_string_null(option)
  }
  let total = buf.len() - 1
  buf.set_int_be(1, total)
  buf.to_bytes()
}

///|
pub impl Message for NegotiateProtocolVersion with fn decode(
  payload : BytesView,
) -> NegotiateProtocolVersion raise WireError {
  guard payload is [i32be(minor), .. rest] else {
    raise WireError::InvalidMessage(
      "NegotiateProtocolVersion: truncated minor version",
    )
  }
  // Read option count (int16be). Must use pattern match on rest.
  let (nopts, r0) = match rest {
    [b0, b1, .. r] => {
      let count = (b0.to_int() << 8) | b1.to_int()
      (count, r)
    }
    _ => (0, rest)
  }
  let options : Array[String] = []
  for r = r0 {
    if options.length() >= nopts {
      break
    }
    let (opt, r1) = read_cstring(r[:])
    options.push(opt)
    continue r1
  }
  NegotiateProtocolVersion::{ newest_minor_version: minor, options }
}

///|
pub impl Message for NegotiateProtocolVersion with fn describe(self) -> String {
  "NegotiateProtocolVersion(minor=\{self.newest_minor_version}, options=\{self.options.length()})"
}
