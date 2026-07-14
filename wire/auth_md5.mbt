///|
/// PostgreSQL MD5 password authentication helper.
///
/// The algorithm (from the PostgreSQL docs):
///   1. inner = md5(password || user)
///   2. outer = md5(hex(inner) || salt)
///   3. Send "md5" + hex(outer) as the password
///
/// Where || denotes byte concatenation, and hex() is lowercase hex encoding.

///|
/// Compute the MD5 password response for PostgreSQL authentication.
///
/// `password` — the plaintext password
/// `user`     — the database user name
/// `salt`     — the 4-byte salt from the server's AuthenticationMD5Password message
///
/// Returns the "md5..." string to send in a PasswordMessage.
pub fn compute_md5_password(
  password : String,
  user : String,
  salt : Bytes,
) -> String {
  // Step 1: md5(password || user)
  let buf = BytesMut::new()
  buf.append_bytes(@utf8.encode(password))
  buf.append_bytes(@utf8.encode(user))
  let inner_hash = @crypto.md5(buf.to_bytes())
  let inner_hex = @crypto.bytes_to_hex_string(inner_hash)

  // Step 2: md5(hex(inner_hash) || salt)
  let buf2 = BytesMut::new()
  buf2.append_bytes(@utf8.encode(inner_hex))
  buf2.append_bytes(salt)
  let outer_hash = @crypto.md5(buf2.to_bytes())
  let outer_hex = @crypto.bytes_to_hex_string(outer_hash)

  "md5" + outer_hex
}
