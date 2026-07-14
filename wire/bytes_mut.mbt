///|
/// Mutable byte buffer with random-access writes, built on `Array[Byte]`.
///
/// Unlike `Buffer` (append-only), `BytesMut` allows writing at any position.
/// Convert to immutable `Bytes` via `to_bytes()` (one copy).
///
/// The typical wire-protocol pattern:
///
/// 1. append type byte + placeholder length
/// 2. append payload
/// 3. overwrite the length bytes via `set_*`
/// 4. `to_bytes()` for the final wire-format `Bytes`
pub(all) struct BytesMut {
  priv data : Array[Byte]
}

///|
pub fn BytesMut::new() -> BytesMut {
  { data: [] }
}

///|
pub fn BytesMut::len(self : BytesMut) -> Int {
  self.data.length()
}

///|
/// Overwrite a single byte at `pos`. Pads with zeros if `pos >= len`.
pub fn BytesMut::set_byte(self : BytesMut, pos : Int, b : Byte) -> Unit {
  while self.data.length() <= pos {
    self.data.push(b'\x00')
  }
  self.data[pos] = b
}

///|
/// Write a 32-bit big-endian integer at `pos` (overwrites 4 bytes).
pub fn BytesMut::set_int_be(self : BytesMut, pos : Int, v : Int) -> Unit {
  self.set_byte(pos, ((v >> 24) & 0xFF).to_byte())
  self.set_byte(pos + 1, ((v >> 16) & 0xFF).to_byte())
  self.set_byte(pos + 2, ((v >> 8) & 0xFF).to_byte())
  self.set_byte(pos + 3, (v & 0xFF).to_byte())
}

///|
/// Append a single byte.
pub fn BytesMut::append_byte(self : BytesMut, b : Byte) -> Unit {
  self.data.push(b)
}

///|
/// Append a 32-bit big-endian integer (4 bytes).
pub fn BytesMut::append_int_be(self : BytesMut, v : Int) -> Unit {
  self.data.push(((v >> 24) & 0xFF).to_byte())
  self.data.push(((v >> 16) & 0xFF).to_byte())
  self.data.push(((v >> 8) & 0xFF).to_byte())
  self.data.push((v & 0xFF).to_byte())
}

///|
/// Append raw bytes.
pub fn BytesMut::append_bytes(self : BytesMut, b : Bytes) -> Unit {
  for i = 0; i < b.length(); i = i + 1 {
    self.data.push(b[i])
  }
}

///|
/// Append a null-terminated UTF-8 string.
pub fn BytesMut::append_string_null(self : BytesMut, s : String) -> Unit {
  let b = @utf8.encode(s)
  self.append_bytes(b)
  self.data.push(b'\x00')
}

///|
/// Convert to immutable `Bytes`. One copy (`Bytes::from_array`).
pub fn BytesMut::to_bytes(self : BytesMut) -> Bytes {
  Bytes::from_array(self.data)
}
