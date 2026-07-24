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
