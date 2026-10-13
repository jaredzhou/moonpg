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
pub extend Stream with @io.Reader::{
  read,
  read_some,
  _direct_read,
  drop,
  read_all,
  read_until,
  read_exactly,
  _get_internal_buffer,
}

///|
pub extend Stream with @io.Writer::{write_once, write, write_reader}

///|
pub extend Stream with Transport::{close}

///|
// ---------------------------------------------------------------------------
// @io.Reader impl — delegates to the inner type
// ---------------------------------------------------------------------------

///|
pub impl @io.Reader for Stream with fn _get_internal_buffer(self : Stream) {
  match self {
    Plain(tcp) => @io.Reader::_get_internal_buffer(tcp)
    Tls(tls) => @io.Reader::_get_internal_buffer(tls)
  }
}

///|
pub impl @io.Reader for Stream with fn _direct_read(
  self : Stream,
  buf : FixedArray[Byte],
  offset~ : Int32,
  max_len~ : Int32,
) -> Int32 {
  match self {
    Plain(tcp) => @io.Reader::_direct_read(tcp, buf, offset~, max_len~)
    Tls(tls) => @io.Reader::_direct_read(tls, buf, offset~, max_len~)
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
  offset~ : Int32,
  len~ : Int32,
) -> Int32 {
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
