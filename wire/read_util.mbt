///|
/// Read a null-terminated string from the front of a `BytesView`.
///
/// Returns the decoded string and the remaining bytes after the null.
fn read_cstring(bytes : BytesView) -> (String, BytesView) raise WireError {
  let null_idx = match bytes.find(b"\x00") {
    Some(i) => i
    None => raise WireError::InvalidMessage("read_cstring: unterminated string")
  }
  let s = @utf8.decode(bytes[0:null_idx]) catch {
    _ => bytes[0:null_idx].to_owned().to_unchecked_string()
  }
  (s, bytes[null_idx + 1:])
}

///|
/// Read a sequence of null-terminated strings, terminated by an
/// empty string (i.e. an immediate null byte: `str\\0str\\0\\0`).
/// Consumes the entire input.
fn read_cstrings(bytes : BytesView) -> Array[String] raise WireError {
  let result : Array[String] = []
  for rest = bytes {
    match rest {
      [b'\x00', ..] => break
      _ => {
        let (s, next) = read_cstring(rest[:])
        result.push(s)
        continue next
      }
    }
  }
  result
}
