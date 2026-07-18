///|
/// Transport abstraction over TCP and TLS connections.
///
/// Combines `@io.Reader`, `@io.Writer`, and `close()` so `RawConn` can
/// work with either a plain TCP socket or a TLS-wrapped connection.

///|
/// A bidirectional stream that can be closed.
///
/// Supertrait of `@io.Reader + @io.Writer` with an explicit `close` method.
pub(open) trait Transport: @io.Reader + @io.Writer {
  fn close(Self) -> Unit
}

///|
/// Concrete transport — either a plain TCP connection or a TLS-wrapped one.
pub(all) enum Stream {
  Plain(@socket.Tcp)
  Tls(@tls.Tls)
}

///|
// ---------------------------------------------------------------------------
// @io.Reader impl — delegates to the inner type
// ---------------------------------------------------------------------------

///|
pub impl @io.Reader for Stream with fn _get_internal_buffer(self : Stream) {
  match self {
    Plain(tcp) => tcp._get_internal_buffer()
    Tls(tls) => tls._get_internal_buffer()
  }
}

///|
pub impl @io.Reader for Stream with fn _direct_read(
  self : Stream,
  buf : FixedArray[Byte],
  offset~ : Int,
  max_len~ : Int,
) -> Int {
  match self {
    Plain(tcp) => tcp._direct_read(buf, offset~, max_len~)
    Tls(tls) => tls._direct_read(buf, offset~, max_len~)
  }
}

///|
// ---------------------------------------------------------------------------
// @io.Writer impl — delegates to the inner type
// ---------------------------------------------------------------------------

///|
pub impl @io.Writer for Stream with fn write_once(
  self : Stream,
  buf : Bytes,
  offset~ : Int,
  len~ : Int,
) -> Int {
  match self {
    Plain(tcp) => tcp.write_once(buf, offset~, len~)
    Tls(tls) => tls.write_once(buf, offset~, len~)
  }
}

///|
// ---------------------------------------------------------------------------
// Transport impl
// ---------------------------------------------------------------------------

///|
pub impl Transport for Stream with fn close(self : Stream) -> Unit {
  match self {
    Plain(tcp) => tcp.close()
    Tls(tls) => tls.close()
  }
}
