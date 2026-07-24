///|
/// `TextCodec` — text-format codec that maps `Value::String` to/from UTF-8 bytes.
///
/// Used for these PostgreSQL types (among others):
/// * text (25), varchar (1043), bpchar (1042), name (19), unknown (705)
///
/// Binary format is not supported — raises `CodecError`.
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
  match format {
    @value.Format::Text =>
      match value {
        @value.Value::String(s) => Some(@utf8.encode(s))
        @value.Value::Null => None
        _ =>
          raise CodecError::CodecError(
            "TextCodec::encode: expected Value::String or Value::Null",
          )
      }
    @value.Format::Binary =>
      raise CodecError::CodecError(
        "TextCodec: binary format not supported for text types",
      )
  }
}

///|
impl Codec for TextCodec with fn decode(
  _self : TextCodec,
  _oid : Int,
  format : @value.Format,
  bytes : Bytes,
) -> @value.Value raise CodecError {
  match format {
    @value.Format::Text => {
      let s = @utf8.decode(bytes) catch { _ => bytes.to_unchecked_string() }
      @value.Value::String(s)
    }
    @value.Format::Binary =>
      raise CodecError::CodecError(
        "TextCodec: binary format not supported for text types",
      )
  }
}

// ===========================================================================
// Tests
// ===========================================================================

///|
test "text_codec_roundtrip_text" {
  let codec = text_codec
  let val = @value.Value::String("hello world")
  let encoded = Codec::encode(codec, text_oid, @value.Format::Text, val).unwrap()
  let decoded = Codec::decode(codec, text_oid, @value.Format::Text, encoded)
  match decoded {
    @value.Value::String(s) => assert_eq(s, "hello world")
    _ => fail("expected Value::String")
  }
}

///|
test "text_codec_binary_raises" {
  let codec = text_codec
  let val = @value.Value::String("test")
  let mut got_error : Bool = false
  let _ = Codec::encode(codec, text_oid, @value.Format::Binary, val) catch {
    _ => {
      got_error = true
      None
    }
  }
  assert_true(got_error, msg="expected CodecError for binary format")
}

///|
test "text_codec_prefer_format" {
  let codec = text_codec
  assert_eq(Codec::prefer_format(codec), @value.Format::Text)
}
