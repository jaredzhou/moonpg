///|
/// Wire-protocol errors.
pub suberror WireError {
  /// Server sent an `ErrorResponse`.
  PgServer(String)
  /// Connection-level failure: TCP, SSL, network.
  Connect(String)
  /// Authentication failure: wrong password, unsupported method.
  Auth(String)
  /// Connection-string / config parsing failure.
  Parse(String)
  /// Message encoding / decoding failure (malformed, truncated, unexpected values).
  InvalidMessage(String)
  /// Wrapped I/O / system error.
  IO(String)
}
