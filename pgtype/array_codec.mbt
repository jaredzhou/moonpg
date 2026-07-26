///|
/// `ArrayCodec` — text format encode/decode for PostgreSQL array types.
///
/// Handles 1-D arrays by delegating element encoding/decoding to an element
/// `Type`'s codec. For now only text format is supported; binary format raises
/// an error.
///
/// Registered for all `_*` array OIDs (e.g. `_int4` → 1007, `_text` → 1009).
pub struct ArrayCodec {
  elem_type : Type
}

///|
/// Create an `ArrayCodec` for the given element type.
pub fn ArrayCodec::new(elem_type : Type) -> ArrayCodec {
  ArrayCodec::{ elem_type, }
}

///|
impl Codec for ArrayCodec with fn prefer_format(_self : ArrayCodec) -> @value.Format {
  @value.Format::Text
}

///|
impl Codec for ArrayCodec with fn encode(
  self : ArrayCodec,
  _oid : Int,
  format : @value.Format,
  value : @value.Value,
) -> Bytes? raise CodecError {
  match value {
    @value.Value::Array(arr) =>
      match format {
        @value.Format::Text => {
          let elem_codec = self.elem_type.codec
          let elem_oid = self.elem_type.oid
          let parts : Array[String] = []
          for i = 0; i < arr.length(); i = i + 1 {
            match arr[i] {
              @value.Value::Null => parts.push("NULL")
              elem => {
                let encoded = Codec::encode(
                  elem_codec,
                  elem_oid,
                  @value.Format::Text,
                  elem,
                ) catch {
                  e => raise e
                }
                match encoded {
                  None => parts.push("NULL")
                  Some(bytes) => {
                    let s = @utf8.decode(bytes) catch {
                      _ => bytes.to_unchecked_string()
                    }
                    if needs_quoting(s) {
                      parts.push("\"" + escape_array_element(s) + "\"")
                    } else {
                      parts.push(s)
                    }
                  }
                }
              }
            }
          }
          let result = "{" + parts.join(",") + "}"
          Some(@utf8.encode(result))
        }
        @value.Format::Binary =>
          raise CodecError::CodecError(
            "ArrayCodec::encode: binary format not yet supported",
          )
      }
    @value.Value::Null => None
    _ =>
      raise CodecError::CodecError(
        "ArrayCodec::encode: expected Value::Array or Value::Null",
      )
  }
}

///|
impl Codec for ArrayCodec with fn decode(
  self : ArrayCodec,
  _oid : Int,
  format : @value.Format,
  bytes : Bytes?,
) -> @value.Value raise CodecError {
  match bytes {
    None => @value.Value::Null
    Some(bytes) =>
      match format {
        @value.Format::Text => {
          let s = @utf8.decode(bytes) catch { _ => bytes.to_unchecked_string() }
          let elements = parse_array_text(s)
          let elem_codec = self.elem_type.codec
          let elem_oid = self.elem_type.oid
          let result : Array[@value.Value] = []
          for i = 0; i < elements.length(); i = i + 1 {
            match elements[i] {
              None => result.push(@value.Value::Null)
              Some(elem_str) => {
                let elem_bytes = @utf8.encode(elem_str)
                let val = Codec::decode(
                  elem_codec,
                  elem_oid,
                  @value.Format::Text,
                  Some(elem_bytes),
                ) catch {
                  e => raise e
                }
                result.push(val)
              }
            }
          }
          @value.Value::Array(result)
        }
        @value.Format::Binary =>
          raise CodecError::CodecError(
            "ArrayCodec::decode: binary format not yet supported",
          )
      }
  }
}

// ===========================================================================
// Array text parser
// ===========================================================================

///|
/// Parse a PostgreSQL array text representation `{elem1,elem2,...}` into a list
/// of element strings.
///
/// Returns `Option[String]` per element: `None` means SQL NULL, `Some(s)` means
/// a non-null element whose text representation is `s`.
///
/// Handles quoted elements (`"..."`) with `\"` and `\\` escape sequences,
/// and distinguishes bare `NULL` from quoted `"NULL"`.
fn parse_array_text(s : String) -> Array[String?] {
  let inner = s.trim()
  guard inner.length() >= 2 &&
    inner[0] == '{' &&
    inner[inner.length() - 1] == '}' else {
    return []
  }
  parse_bare(inner[1:inner.length() - 1], [])
}

///|
/// Parse comma-separated elements by pattern-matching the first character.
fn parse_bare(s : StringView, results : Array[String?]) -> Array[String?] {
  match s {
    "" => results
    ['"', .. rest] => {
      let (elem, rest2) = take_quoted(rest)
      parse_bare(rest2, results + [Some(elem)])
    }
    [',', .. rest] => parse_bare(rest, push_empty(results))
    _ => {
      let (text, rest) = take_until_delim(s)
      parse_bare(rest, push_bare(results, text))
    }
  }
}

///|
/// Consume characters until `,`, `"`, or end-of-string.
/// Returns `(consumed_text, remaining)`.
fn take_until_delim(s : StringView) -> (String, StringView) {
  match s {
    "" => ("", "")
    [',', .. rest] => ("", rest)
    ['"', .. rest] => ("", rest)
    [ch, .. rest] => {
      let (cur, rest2) = take_until_delim(rest)
      (ch.to_string() + cur, rest2)
    }
  }
}

///|
/// Consume a quoted element `"..."`. `s` starts after the opening `"`.
/// Returns the unescaped content and the StringView after the closing `"`.
fn take_quoted(s : StringView) -> (String, StringView) {
  let (raw, rest) = take_quoted_raw(s, "")
  (unescape(raw), rest)
}

///|
/// Consume raw content of a quoted element until the unescaped closing `"`.
/// `cur` accumulates characters (with escape sequences preserved).
fn take_quoted_raw(s : StringView, cur : String) -> (String, StringView) {
  match s {
    "" => (cur, s)
    ['"', .. rest] =>
      if ends_with_odd_backslashes(cur) {
        take_quoted_raw(rest, cur + "\"")
      } else {
        (cur, skip_to_comma(rest))
      }
    ['\\', .. rest] => take_quoted_raw(rest, cur + "\\")
    [ch, .. rest] => take_quoted_raw(rest, cur + ch.to_string())
  }
}

///|
/// Skip whitespace until a comma or end-of-string.
fn skip_to_comma(s : StringView) -> StringView {
  match s {
    "" => ""
    [',', .. rest] => rest
    [_, .. rest] => skip_to_comma(rest)
  }
}

///|
/// Check whether `s` ends with an odd number of consecutive backslashes.
fn ends_with_odd_backslashes(s : String) -> Bool {
  s.length() > 0 &&
  s[s.length() - 1] == '\\' &&
  count_trailing(s, s.length() - 1) % 2 == 1
}

///|
/// Count consecutive backslashes scanning left from position `i`.
fn count_trailing(s : String, i : Int) -> Int {
  if i < 0 || s[i] != '\\' {
    0
  } else {
    1 + count_trailing(s, i - 1)
  }
}

///|
/// Trim and classify a bare element as NULL or a value.
fn push_bare(results : Array[String?], text : String) -> Array[String?] {
  let t = text.trim()
  if t == "NULL" {
    results + [None]
  } else {
    results + [Some(t.to_owned())]
  }
}

///|
/// Push an empty element (between two commas).
fn push_empty(results : Array[String?]) -> Array[String?] {
  results + [None]
}

///|
/// Unescape a PG array quoted content: `\<any>` → `<any>`.
fn unescape(s : StringView) -> String {
  match s {
    "" => ""
    ['\\', .. rest] =>
      match rest {
        "" => ""
        [ch, .. rest2] => ch.to_string() + unescape(rest2)
      }
    [ch, .. rest] => ch.to_string() + unescape(rest)
  }
}

// ===========================================================================
// Array text encoder helpers
// ===========================================================================

///|
/// Check whether an element\'s text representation needs to be double-quoted
/// in the PG array text format.
fn needs_quoting(s : String) -> Bool {
  if s == "" || s == "NULL" {
    return true
  }
  for i = 0; i < s.length(); i = i + 1 {
    let ch = s[i]
    if ch == ',' ||
      ch == '{' ||
      ch == '}' ||
      ch == '"' ||
      ch == '\\' ||
      ch == ' ' ||
      ch == '\t' ||
      ch == '\n' ||
      ch == '\r' {
      return true
    }
  }
  false
}

///|
/// Escape a value for use inside a PG array quoted element:
/// `\` → `\\`, `"` → `\"`.
fn escape_array_element(s : String) -> String {
  let mut result = ""
  for i = 0; i < s.length(); i = i + 1 {
    let ch = s[i]
    if ch == '\\' || ch == '"' {
      result = result + "\\"
    }
    result = result + s[i:i + 1].to_owned()
  }
  result
}

// ===========================================================================
// Tests
// ===========================================================================

///|
test "array_codec_int4_roundtrip" {
  let elem_type = default_map.type_for_oid(int4_oid).unwrap()
  let codec = ArrayCodec::new(elem_type)
  let val = @value.Value::Array([
    @value.Value::Int(1),
    @value.Value::Int(2),
    @value.Value::Int(42),
  ])
  let encoded = Codec::encode(codec, int4_array_oid, @value.Format::Text, val)
  let decoded = Codec::decode(
    codec,
    int4_array_oid,
    @value.Format::Text,
    encoded,
  )
  match decoded {
    @value.Value::Array(arr) => {
      assert_eq(arr.length(), 3)
      assert_eq(arr[0], @value.Value::Int(1))
      assert_eq(arr[1], @value.Value::Int(2))
      assert_eq(arr[2], @value.Value::Int(42))
    }
    _ => fail("expected Value::Array")
  }
}

///|
test "array_codec_int4_with_null" {
  let elem_type = default_map.type_for_oid(int4_oid).unwrap()
  let codec = ArrayCodec::new(elem_type)
  let val = @value.Value::Array([
    @value.Value::Int(1),
    @value.Value::Null,
    @value.Value::Int(3),
  ])
  let encoded = Codec::encode(codec, int4_array_oid, @value.Format::Text, val)
  let decoded = Codec::decode(
    codec,
    int4_array_oid,
    @value.Format::Text,
    encoded,
  )
  match decoded {
    @value.Value::Array(arr) => {
      assert_eq(arr.length(), 3)
      assert_eq(arr[0], @value.Value::Int(1))
      assert_eq(arr[1], @value.Value::Null)
      assert_eq(arr[2], @value.Value::Int(3))
    }
    _ => fail("expected Value::Array")
  }
}

///|
test "array_codec_bool_roundtrip" {
  let elem_type = default_map.type_for_oid(bool_oid).unwrap()
  let codec = ArrayCodec::new(elem_type)
  let val = @value.Value::Array([
    @value.Value::Bool(true),
    @value.Value::Bool(false),
    @value.Value::Bool(true),
  ])
  let encoded = Codec::encode(codec, bool_array_oid, @value.Format::Text, val)
  let decoded = Codec::decode(
    codec,
    bool_array_oid,
    @value.Format::Text,
    encoded,
  )
  match decoded {
    @value.Value::Array(arr) => {
      assert_eq(arr.length(), 3)
      assert_eq(arr[0], @value.Value::Bool(true))
      assert_eq(arr[1], @value.Value::Bool(false))
      assert_eq(arr[2], @value.Value::Bool(true))
    }
    _ => fail("expected Value::Array")
  }
}

///|
test "array_codec_text_roundtrip" {
  let elem_type = default_map.type_for_oid(text_oid).unwrap()
  let codec = ArrayCodec::new(elem_type)
  let val = @value.Value::Array([
    @value.Value::String("hello"),
    @value.Value::String("world"),
  ])
  let encoded = Codec::encode(codec, text_array_oid, @value.Format::Text, val)
  let decoded = Codec::decode(
    codec,
    text_array_oid,
    @value.Format::Text,
    encoded,
  )
  match decoded {
    @value.Value::Array(arr) => {
      assert_eq(arr.length(), 2)
      assert_eq(arr[0], @value.Value::String("hello"))
      assert_eq(arr[1], @value.Value::String("world"))
    }
    _ => fail("expected Value::Array")
  }
}

///|
test "array_codec_empty" {
  let elem_type = default_map.type_for_oid(int4_oid).unwrap()
  let codec = ArrayCodec::new(elem_type)
  let val = @value.Value::Array([])
  let encoded = Codec::encode(codec, int4_array_oid, @value.Format::Text, val)
  let decoded = Codec::decode(
    codec,
    int4_array_oid,
    @value.Format::Text,
    encoded,
  )
  match decoded {
    @value.Value::Array(arr) => assert_eq(arr.length(), 0)
    _ => fail("expected Value::Array")
  }
}

///|
test "array_codec_null_value" {
  let elem_type = default_map.type_for_oid(int4_oid).unwrap()
  let codec = ArrayCodec::new(elem_type)
  let encoded = Codec::encode(
    codec,
    int4_array_oid,
    @value.Format::Text,
    @value.Value::Null,
  )
  assert_eq(encoded, None)
  let decoded = Codec::decode(codec, int4_array_oid, @value.Format::Text, None)
  assert_eq(decoded, @value.Value::Null)
}

///|
test "array_codec_prefer_format" {
  let elem_type = default_map.type_for_oid(int4_oid).unwrap()
  let codec = ArrayCodec::new(elem_type)
  assert_eq(Codec::prefer_format(codec), @value.Format::Text)
}

///|
test "parse_array_text_basic" {
  let result = parse_array_text("{1,2,3}")
  assert_eq(result.length(), 3)
  assert_eq(result[0], Some("1"))
  assert_eq(result[1], Some("2"))
  assert_eq(result[2], Some("3"))
}

///|
test "parse_array_text_with_null" {
  let result = parse_array_text("{1,NULL,3}")
  assert_eq(result.length(), 3)
  assert_eq(result[0], Some("1"))
  assert_eq(result[1], None)
  assert_eq(result[2], Some("3"))
}

///|
test "parse_array_text_empty" {
  let result = parse_array_text("{}")
  assert_eq(result.length(), 0)
}

///|
test "parse_array_text_single" {
  let result = parse_array_text("{42}")
  assert_eq(result.length(), 1)
  assert_eq(result[0], Some("42"))
}

// --- Quoted-element parser tests ---

///|
test "parse_array_text_quoted_simple" {
  let result = parse_array_text("{\"hello\"}")
  assert_eq(result.length(), 1)
  assert_eq(result[0], Some("hello"))
}

///|
test "parse_array_text_quoted_with_comma" {
  let result = parse_array_text("{\"hello, world\",foo}")
  assert_eq(result.length(), 2)
  assert_eq(result[0], Some("hello, world"))
  assert_eq(result[1], Some("foo"))
}

///|
test "parse_array_text_quoted_with_braces" {
  let result = parse_array_text("{\"a{b}c\",plain}")
  assert_eq(result.length(), 2)
  assert_eq(result[0], Some("a{b}c"))
  assert_eq(result[1], Some("plain"))
}

///|
test "parse_array_text_escaped_quote" {
  let result = parse_array_text("{\"say \\\"hi\\\"\"}")
  assert_eq(result.length(), 1)
  assert_eq(result[0], Some("say \"hi\""))
}

///|
test "parse_array_text_escaped_backslash" {
  let result = parse_array_text("{\"a\\\\b\"}")
  assert_eq(result.length(), 1)
  assert_eq(result[0], Some("a\\b"))
}

///|
test "parse_array_text_null_vs_quoted_null" {
  let result = parse_array_text("{NULL,\"NULL\"}")
  assert_eq(result.length(), 2)
  assert_eq(result[0], None)
  assert_eq(result[1], Some("NULL"))
}

///|
test "parse_array_text_mixed" {
  let result = parse_array_text("{1,\"two, three\",NULL,four}")
  assert_eq(result.length(), 4)
  assert_eq(result[0], Some("1"))
  assert_eq(result[1], Some("two, three"))
  assert_eq(result[2], None)
  assert_eq(result[3], Some("four"))
}

// --- Encoder quoting + roundtrip tests ---

///|
test "array_codec_text_with_comma_roundtrip" {
  let elem_type = default_map.type_for_oid(text_oid).unwrap()
  let codec = ArrayCodec::new(elem_type)
  let val = @value.Value::Array([
    @value.Value::String("hello, world"),
    @value.Value::String("foo"),
  ])
  let encoded = Codec::encode(codec, text_array_oid, @value.Format::Text, val)
  let decoded = Codec::decode(
    codec,
    text_array_oid,
    @value.Format::Text,
    encoded,
  )
  match decoded {
    @value.Value::Array(arr) => {
      assert_eq(arr.length(), 2)
      assert_eq(arr[0], @value.Value::String("hello, world"))
      assert_eq(arr[1], @value.Value::String("foo"))
    }
    _ => fail("expected Value::Array")
  }
}

///|
test "array_codec_text_with_quote_roundtrip" {
  let elem_type = default_map.type_for_oid(text_oid).unwrap()
  let codec = ArrayCodec::new(elem_type)
  let val = @value.Value::Array([
    @value.Value::String("say \"hi\""),
    @value.Value::String("plain"),
  ])
  let encoded = Codec::encode(codec, text_array_oid, @value.Format::Text, val)
  let decoded = Codec::decode(
    codec,
    text_array_oid,
    @value.Format::Text,
    encoded,
  )
  match decoded {
    @value.Value::Array(arr) => {
      assert_eq(arr.length(), 2)
      assert_eq(arr[0], @value.Value::String("say \"hi\""))
      assert_eq(arr[1], @value.Value::String("plain"))
    }
    _ => fail("expected Value::Array")
  }
}

///|
test "array_codec_text_null_vs_string_null_roundtrip" {
  let elem_type = default_map.type_for_oid(text_oid).unwrap()
  let codec = ArrayCodec::new(elem_type)
  let val = @value.Value::Array([
    @value.Value::Null,
    @value.Value::String("NULL"),
  ])
  let encoded = Codec::encode(codec, text_array_oid, @value.Format::Text, val)
  let decoded = Codec::decode(
    codec,
    text_array_oid,
    @value.Format::Text,
    encoded,
  )
  match decoded {
    @value.Value::Array(arr) => {
      assert_eq(arr.length(), 2)
      assert_eq(arr[0], @value.Value::Null)
      assert_eq(arr[1], @value.Value::String("NULL"))
    }
    _ => fail("expected Value::Array")
  }
}

///|
test "array_codec_json_roundtrip" {
  let elem_type = default_map.type_for_oid(json_oid).unwrap()
  let codec = ArrayCodec::new(elem_type)
  let j1 = @json.parse("{\"a\":1}")
  let j2 = @json.parse("[1,2,3]")
  let val = @value.Value::Array([@value.Value::Json(j1), @value.Value::Json(j2)])
  let encoded = Codec::encode(codec, json_array_oid, @value.Format::Text, val)
  let decoded = Codec::decode(
    codec,
    json_array_oid,
    @value.Format::Text,
    encoded,
  )
  match decoded {
    @value.Value::Array(arr) => {
      assert_eq(arr.length(), 2)
      match arr[0] {
        @value.Value::Json(j) => assert_eq(j.stringify(), "{\"a\":1}")
        _ => fail("expected Json")
      }
      match arr[1] {
        @value.Value::Json(j) => assert_eq(j.stringify(), "[1,2,3]")
        _ => fail("expected Json")
      }
    }
    _ => fail("expected Value::Array")
  }
}

///|
test "parse_array_text_escaped_backslash_before_quote" {
  let result = parse_array_text("{\"a\\\\\"}")
  assert_eq(result.length(), 1)
  assert_eq(result[0], Some("a\\"))
}

///|
test "needs_quoting_comma" {
  assert_true(needs_quoting("hello, world"))
}

///|
test "needs_quoting_quote" {
  assert_true(needs_quoting("say \"hi\""))
}

///|
test "needs_quoting_brace" {
  assert_true(needs_quoting("has{brace"))
}

///|
test "needs_quoting_null_string" {
  assert_true(needs_quoting("NULL"))
}

///|
test "needs_quoting_empty" {
  assert_true(needs_quoting(""))
}

///|
test "needs_quoting_simple" {
  assert_false(needs_quoting("simple"))
}

///|
test "escape_array_element_basic" {
  let s = "say \"hi\""
  let escaped = escape_array_element(s)
  assert_eq(escaped, "say \\\"hi\\\"")
}

///|
test "escape_array_element_backslash" {
  let s = "a\\b"
  let escaped = escape_array_element(s)
  assert_eq(escaped, "a\\\\b")
}
