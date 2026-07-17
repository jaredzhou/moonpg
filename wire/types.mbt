///|
/// PostgreSQL protocol version constants.
pub enum ProtocolVersion {
  V3_0 // 196608 = major 3, minor 0
  V3_2 // 196610 = major 3, minor 2 (supports secret_key)
} derive(Debug, Eq)

///|
pub fn ProtocolVersion::to_int32(self : ProtocolVersion) -> Int {
  match self {
    V3_0 => 196608
    V3_2 => 196610
  }
}

///|
pub fn ProtocolVersion::minor(self : ProtocolVersion) -> Int {
  match self {
    V3_0 => 0
    V3_2 => 2
  }
}

///|
/// SSL request magic number.
pub const SSL_REQUEST_CODE : Int = 80877103

///|
/// Transaction status indicator from ReadyForQuery.
pub(all) enum TransactionStatus {
  Idle // 'I' — not in a transaction block
  InBlock // 'T' — in a transaction block
  Failed // 'E' — in a failed transaction block
} derive(Debug, Eq)

///|
pub fn TransactionStatus::from_byte(
  b : Byte,
) -> TransactionStatus raise WireError {
  match b {
    b'I' => Idle
    b'T' => InBlock
    b'E' => Failed
    _ =>
      raise WireError::InvalidMessage(
        "unknown ReadyForQuery transaction status byte",
      )
  }
}

///|
pub fn TransactionStatus::to_byte(self : TransactionStatus) -> Byte {
  match self {
    Idle => b'I'
    InBlock => b'T'
    Failed => b'E'
  }
}

///|
pub impl Show for TransactionStatus with fn output(self, logger) {
  match self {
    Idle => logger.write_string("I")
    InBlock => logger.write_string("T")
    Failed => logger.write_string("E")
  }
}

///|
/// Authentication method requested by the server.
pub(all) enum AuthMethod {
  Ok // 0
  CleartextPassword // 3
  MD5Password // 5
  SASL // 10
  SASLContinue // 11
  SASLFinal // 12
} derive(Debug, Eq)

///|
pub fn AuthMethod::from_int(v : Int) -> AuthMethod raise WireError {
  match v {
    0 => Ok
    3 => CleartextPassword
    5 => MD5Password
    10 => SASL
    11 => SASLContinue
    12 => SASLFinal
    n => raise WireError::InvalidMessage("unknown auth method: \{n}")
  }
}

///|
/// Message type bytes (frontend → server).
pub const MSG_PASSWORD : Byte = b'p'

///|
pub const MSG_QUERY : Byte = b'Q'

///|
pub const MSG_TERMINATE : Byte = b'X'

///|
pub const MSG_PARSE : Byte = b'P'

///|
pub const MSG_BIND : Byte = b'B'

///|
pub const MSG_DESCRIBE : Byte = b'D'

///|
pub const MSG_EXECUTE : Byte = b'E'

///|
pub const MSG_CLOSE : Byte = b'C'

///|
pub const MSG_SYNC : Byte = b'S'

///|
pub const MSG_FLUSH : Byte = b'H'

///|
/// Message type bytes (server → client).
pub const MSG_AUTHENTICATION : Byte = b'R'

///|
pub const MSG_PARAMETER_STATUS : Byte = b'S'

///|
pub const MSG_BACKEND_KEY_DATA : Byte = b'K'

///|
pub const MSG_READY_FOR_QUERY : Byte = b'Z'

///|
pub const MSG_ROW_DESCRIPTION : Byte = b'T'

///|
pub const MSG_DATA_ROW : Byte = b'D'

///|
pub const MSG_COMMAND_COMPLETE : Byte = b'C'

///|
pub const MSG_ERROR_RESPONSE : Byte = b'E'

///|
pub const MSG_NOTICE_RESPONSE : Byte = b'N'

///|
pub const MSG_NOTIFICATION_RESPONSE : Byte = b'A'

///|
pub const MSG_PARSE_COMPLETE : Byte = b'1'

///|
pub const MSG_BIND_COMPLETE : Byte = b'2'

///|
pub const MSG_CLOSE_COMPLETE : Byte = b'3'

///|
pub const MSG_EMPTY_QUERY : Byte = b'I'

///|
pub const MSG_PORTAL_SUSPENDED : Byte = b's'

///|
pub const MSG_NO_DATA : Byte = b'n'

///|
pub const MSG_PARAMETER_DESCRIPTION : Byte = b't'

///|
pub const MSG_COPY_IN_RESPONSE : Byte = b'G'

///|
pub const MSG_COPY_OUT_RESPONSE : Byte = b'H'

///|
pub const MSG_COPY_BOTH_RESPONSE : Byte = b'W'

///|
pub const MSG_COPY_DATA : Byte = b'd'

///|
pub const MSG_COPY_DONE : Byte = b'c'

///|
/// `CopyFail` is frontend-only (server never sends it).
pub const MSG_COPY_FAIL : Byte = b'f'

///|
/// NegotiateProtocolVersion ('v') — PG 17+ protocol version negotiation.
pub const MSG_NEGOTIATE_PROTOCOL_VERSION : Byte = b'v'
