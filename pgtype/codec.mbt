///|
/// Codec error type.
pub(all) suberror CodecError {
  CodecError(String)
} derive(Debug)

///|
/// Codec converts between `Value` and PostgreSQL wire-format bytes.
///
/// Each codec is a stateless struct implementing this trait. The `oid`
/// parameter allows a single codec to handle multiple OIDs (e.g., `IntCodec`
/// handles int2/int4/int8 with different byte widths based on OID).
pub(open) trait Codec {
  /// Preferred wire format for this codec. Most codecs return `Format::Binary`;
  /// codecs that only support text (e.g., JSON) return `Format::Text`.
  fn prefer_format(Self) -> @value.Format
  /// Encode a `Value` into wire-format bytes.
  fn encode(Self, oid : Int, format : @value.Format, value : @value.Value) -> Bytes raise CodecError
  /// Decode wire-format bytes into a `Value`.
  fn decode(Self, oid : Int, format : @value.Format, bytes : Bytes) -> @value.Value raise CodecError
}

// ===========================================================================
// CodecImpl — enum-based codec dispatch
// ===========================================================================

///|
/// Enum wrapping all concrete codec implementations. Used in `Type.codec`
/// to enable polymorphic codec dispatch without trait objects.
///
/// Each variant wraps a stateless codec struct. New codec types are added
/// as new variants here and dispatched in the `encode`/`decode` methods below.
pub(all) enum CodecImpl {
  Text(TextCodec)
  Bool(BoolCodec)
  Int2(Int2Codec)
  Int4(Int4Codec)
  Int8(Int8Codec)
  Float4(Float4Codec)
  Float8(Float8Codec)
  Bytea(ByteaCodec)
  JSON(JSONCodec)
  JSONB(JSONBCodec)
  Timestamp(TimestampCodec)
  Timestamptz(TimestamptzCodec)
}

///|
/// Dispatch `prefer_format` through the codec enum.
pub fn CodecImpl::prefer_format(self : CodecImpl) -> @value.Format {
  match self {
    Text(c) => Codec::prefer_format(c)
    Bool(c) => Codec::prefer_format(c)
    Int2(c) => Codec::prefer_format(c)
    Int4(c) => Codec::prefer_format(c)
    Int8(c) => Codec::prefer_format(c)
    Float4(c) => Codec::prefer_format(c)
    Float8(c) => Codec::prefer_format(c)
    Bytea(c) => Codec::prefer_format(c)
    JSON(c) => Codec::prefer_format(c)
    JSONB(c) => Codec::prefer_format(c)
    Timestamp(c) => Codec::prefer_format(c)
    Timestamptz(c) => Codec::prefer_format(c)
  }
}

///|
/// Dispatch `encode` through the codec enum.
pub fn CodecImpl::encode(
  self : CodecImpl,
  oid : Int,
  format : @value.Format,
  value : @value.Value,
) -> Bytes raise CodecError {
  match self {
    Text(c) => Codec::encode(c, oid, format, value)
    Bool(c) => Codec::encode(c, oid, format, value)
    Int2(c) => Codec::encode(c, oid, format, value)
    Int4(c) => Codec::encode(c, oid, format, value)
    Int8(c) => Codec::encode(c, oid, format, value)
    Float4(c) => Codec::encode(c, oid, format, value)
    Float8(c) => Codec::encode(c, oid, format, value)
    Bytea(c) => Codec::encode(c, oid, format, value)
    JSON(c) => Codec::encode(c, oid, format, value)
    JSONB(c) => Codec::encode(c, oid, format, value)
    Timestamp(c) => Codec::encode(c, oid, format, value)
    Timestamptz(c) => Codec::encode(c, oid, format, value)
  }
}

///|
/// Dispatch `decode` through the codec enum.
pub fn CodecImpl::decode(
  self : CodecImpl,
  oid : Int,
  format : @value.Format,
  bytes : Bytes,
) -> @value.Value raise CodecError {
  match self {
    Text(c) => Codec::decode(c, oid, format, bytes)
    Bool(c) => Codec::decode(c, oid, format, bytes)
    Int2(c) => Codec::decode(c, oid, format, bytes)
    Int4(c) => Codec::decode(c, oid, format, bytes)
    Int8(c) => Codec::decode(c, oid, format, bytes)
    Float4(c) => Codec::decode(c, oid, format, bytes)
    Float8(c) => Codec::decode(c, oid, format, bytes)
    Bytea(c) => Codec::decode(c, oid, format, bytes)
    JSON(c) => Codec::decode(c, oid, format, bytes)
    JSONB(c) => Codec::decode(c, oid, format, bytes)
    Timestamp(c) => Codec::decode(c, oid, format, bytes)
    Timestamptz(c) => Codec::decode(c, oid, format, bytes)
  }
}
