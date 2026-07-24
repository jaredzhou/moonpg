///|
/// `TextCodec` — text format encodes `Value::String` as UTF-8 bytes.
/// Binary format is identical — decodes bytes as UTF-8 string.
///
/// Used for these PostgreSQL types (among others):
/// * text (25), varchar (1043), bpchar (1042), name (19), unknown (705)
pub struct TextCodec {}

///|
/// Singleton instance referenced by `CodecImpl::Text(...)`.
pub let text_codec : TextCodec = TextCodec::{  }

///|
impl Codec for TextCodec with fn prefer_format(_self : TextCodec) -> @value.Format {
  @value.Format::Text
}

///|
impl Codec for TextCodec with fn encode(
  _self : TextCodec,
  _oid : Int,
  format : @value.Format,
  value : @value.Value,
) -> Bytes? raise CodecError {
  match value {
    @value.Value::String(s) => Some(@utf8.encode(s))
    @value.Value::Json(j) => Some(@utf8.encode(j.stringify()))
    @value.Value::Null => None
    _ =>
      raise CodecError::CodecError(
        "TextCodec::encode: expected Value::String or Value::Null",
      )
  }
}

///|
impl Codec for TextCodec with fn decode(
  _self : TextCodec,
  _oid : Int,
  _format : @value.Format,
  bytes : Bytes?,
) -> @value.Value raise CodecError {
  match bytes {
    None => @value.Value::Null
    Some(bytes) => {
      let s = @utf8.decode(bytes) catch { _ => bytes.to_unchecked_string() }
      @value.Value::String(s)
    }
  }
}

// ===========================================================================
// Tests
// ===========================================================================

///|
test "text_codec_roundtrip_text" {
  let codec = text_codec
  let val = @value.Value::String("hello world")
  let encoded = Codec::encode(codec, text_oid, @value.Format::Text, val)
  let decoded = Codec::decode(codec, text_oid, @value.Format::Text, encoded)
  match decoded {
    @value.Value::String(s) => assert_eq(s, "hello world")
    _ => fail("expected Value::String")
  }
}

///|
test "text_codec_roundtrip_binary" {
  let codec = text_codec
  let val = @value.Value::String("hello binary")
  let encoded = Codec::encode(codec, text_oid, @value.Format::Binary, val)
  let decoded = Codec::decode(codec, text_oid, @value.Format::Binary, encoded)
  match decoded {
    @value.Value::String(s) => assert_eq(s, "hello binary")
    _ => fail("expected Value::String")
  }
}

///|
test "text_codec_prefer_format" {
  let codec = text_codec
  assert_eq(Codec::prefer_format(codec), @value.Format::Text)
}

// --- Edge cases ---

///|
test "text_codec_null_roundtrip" {
  let codec = text_codec
  let encoded = Codec::encode(
    codec,
    text_oid,
    @value.Format::Text,
    @value.Value::Null,
  )
  assert_eq(encoded, None)
  let decoded = Codec::decode(codec, text_oid, @value.Format::Text, None)
  assert_eq(decoded, @value.Value::Null)
}

///|
test "text_codec_empty_string" {
  let codec = text_codec
  let encoded = Codec::encode(
    codec,
    text_oid,
    @value.Format::Text,
    @value.Value::String(""),
  )
  let decoded = Codec::decode(codec, text_oid, @value.Format::Text, encoded)
  assert_eq(decoded, @value.Value::String(""))
}

///|
test "text_codec_json_compat" {
  let codec = text_codec
  let j = @json.parse("{\"a\":1}")
  // TextCodec stringifies Json
  let encoded = Codec::encode(
    codec,
    text_oid,
    @value.Format::Text,
    @value.Value::Json(j),
  )
  let decoded = Codec::decode(codec, text_oid, @value.Format::Text, encoded)
  match decoded {
    @value.Value::String(s) => assert_eq(s, "{\"a\":1}")
    _ => fail("expected Value::String from Json compat")
  }
}
