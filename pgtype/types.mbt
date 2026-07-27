///|
/// PostgreSQL type system: `Type`, `TypeMap`, OID constants, and the default
/// type registry. &Codec implementations live in separate files.

// ===========================================================================
// Type
// ===========================================================================

///|
/// A registered PostgreSQL data type with its codec.
pub(all) struct Type {
  name : String
  oid : Int
  codec : &Codec
}

///|
fn Type::new(name : String, oid : Int, codec : &Codec) -> Type {
  Type::{ name, oid, codec }
}

// ===========================================================================
// TypeMap
// ===========================================================================

///|
/// Registry of PostgreSQL type OID ↔ name ↔ codec mappings.
pub(all) struct TypeMap {
  oid_to_type : @hashmap.HashMap[Int, Type]
  name_to_type : @hashmap.HashMap[String, Type]
  data_type_to_oid : @hashmap.HashMap[String, Int]
}

///|
fn TypeMap::new() -> TypeMap {
  {
    oid_to_type: @hashmap.HashMap([], capacity=200),
    name_to_type: @hashmap.HashMap([], capacity=200),
    data_type_to_oid: @hashmap.HashMap([], capacity=50),
  }
}

///|
/// Register a type with its name, OID, and codec.
fn TypeMap::register(
  self : TypeMap,
  name : String,
  oid : Int,
  codec : &Codec,
) -> TypeMap {
  let t = Type::new(name, oid, codec)
  self.oid_to_type.set(oid, Type::{ ..t })
  self.name_to_type.set(name, Type::{ ..t })
  self
}

///|
/// Register an `information_schema.data_type` alias for the given OID.
fn TypeMap::register_data_type(
  self : TypeMap,
  name : String,
  oid : Int,
) -> TypeMap {
  self.data_type_to_oid.set(name, oid)
  self
}

///|
/// Look up the codec for an OID. Returns a `Text&Codec` as fallback for
/// unknown OIDs (matching pgx behaviour).
pub fn TypeMap::codec_for(self : TypeMap, oid : Int) -> &Codec {
  match self.oid_to_type.get(oid) {
    Some(t) => t.codec
    None => text_codec
  }
}

///|
/// Look up a type by OID. Returns `None` for unknown OIDs.
pub fn TypeMap::type_for_oid(self : TypeMap, oid : Int) -> Type? {
  self.oid_to_type.get(oid)
}

///|
/// Look up a type by canonical PG name. Returns `None` for unknown names.
pub fn TypeMap::type_for_name(self : TypeMap, name : String) -> Type? {
  self.name_to_type.get(name)
}

///|
/// Look up a type by `information_schema.data_type` name.
/// Returns `None` for unknown names.
pub fn TypeMap::type_for_data_type(self : TypeMap, name : String) -> Type? {
  match self.data_type_to_oid.get(name) {
    None => None
    Some(oid) => self.oid_to_type.get(oid)
  }
}

///|
/// Iterate over all registered types. Yields `(oid, Type)` pairs.
pub fn TypeMap::iter(self : TypeMap) -> Iter[(Int, Type)] {
  self.oid_to_type.iter()
}

///|
/// Iterate over all `information_schema.data_type` aliases.
/// Yields `(name, oid)` pairs.
pub fn TypeMap::iter_data_types(self : TypeMap) -> Iter[(String, Int)] {
  self.data_type_to_oid.iter()
}

// ===========================================================================
// OID constants — for compile-time reference
// ===========================================================================

///|
/// Base types
pub let bool_oid : Int = 16

///|
pub let bytea_oid : Int = 17

///|
pub let char_oid : Int = 18

///|
pub let name_oid : Int = 19

///|
pub let int8_oid : Int = 20

///|
pub let int2_oid : Int = 21

///|
pub let int4_oid : Int = 23

///|
pub let text_oid : Int = 25

///|
pub let oid_oid : Int = 26

///|
pub let tid_oid : Int = 27

///|
pub let xid_oid : Int = 28

///|
pub let cid_oid : Int = 29

///|
pub let json_oid : Int = 114

///|
pub let xml_oid : Int = 142

///|
pub let point_oid : Int = 600

///|
pub let lseg_oid : Int = 601

///|
pub let path_oid : Int = 602

///|
pub let box_oid : Int = 603

///|
pub let polygon_oid : Int = 604

///|
pub let line_oid : Int = 628

///|
pub let cidr_oid : Int = 650

///|
pub let float4_oid : Int = 700

///|
pub let float8_oid : Int = 701

///|
pub let unknown_oid : Int = 705

///|
pub let circle_oid : Int = 718

///|
pub let macaddr8_oid : Int = 774

///|
pub let macaddr_oid : Int = 829

///|
pub let inet_oid : Int = 869

///|
pub let aclitem_oid : Int = 1033

///|
pub let bpchar_oid : Int = 1042

///|
pub let varchar_oid : Int = 1043

///|
pub let date_oid : Int = 1082

///|
pub let time_oid : Int = 1083

///|
pub let timestamp_oid : Int = 1114

///|
pub let timestamptz_oid : Int = 1184

///|
pub let interval_oid : Int = 1186

///|
pub let timetz_oid : Int = 1266

///|
pub let bit_oid : Int = 1560

///|
pub let varbit_oid : Int = 1562

///|
pub let numeric_oid : Int = 1700

///|
pub let record_oid : Int = 2249

///|
pub let uuid_oid : Int = 2950

///|
pub let tsvector_oid : Int = 3614

///|
pub let jsonb_oid : Int = 3802

///|
pub let jsonpath_oid : Int = 4072

///|
pub let xid8_oid : Int = 5069

///|
/// Range types
pub let int4range_oid : Int = 3904

///|
pub let numrange_oid : Int = 3906

///|
pub let tsrange_oid : Int = 3908

///|
pub let tstzrange_oid : Int = 3910

///|
pub let daterange_oid : Int = 3912

///|
pub let int8range_oid : Int = 3926

///|
/// Multirange types
pub let int4multirange_oid : Int = 4451

///|
pub let nummultirange_oid : Int = 4532

///|
pub let tsmultirange_oid : Int = 4533

///|
pub let tstzmultirange_oid : Int = 4534

///|
pub let datemultirange_oid : Int = 4535

///|
pub let int8multirange_oid : Int = 4536

///|
/// Array types
pub let bool_array_oid : Int = 1000

///|
pub let bytea_array_oid : Int = 1001

///|
pub let char_array_oid : Int = 1002

///|
pub let name_array_oid : Int = 1003

///|
pub let int2_array_oid : Int = 1005

///|
pub let int4_array_oid : Int = 1007

///|
pub let text_array_oid : Int = 1009

///|
pub let tid_array_oid : Int = 1010

///|
pub let xid_array_oid : Int = 1011

///|
pub let cid_array_oid : Int = 1012

///|
pub let bpchar_array_oid : Int = 1014

///|
pub let varchar_array_oid : Int = 1015

///|
pub let int8_array_oid : Int = 1016

///|
pub let point_array_oid : Int = 1017

///|
pub let lseg_array_oid : Int = 1018

///|
pub let path_array_oid : Int = 1019

///|
pub let box_array_oid : Int = 1020

///|
pub let float4_array_oid : Int = 1021

///|
pub let float8_array_oid : Int = 1022

///|
pub let polygon_array_oid : Int = 1027

///|
pub let oid_array_oid : Int = 1028

///|
pub let aclitem_array_oid : Int = 1034

///|
pub let macaddr_array_oid : Int = 1040

///|
pub let inet_array_oid : Int = 1041

///|
pub let date_array_oid : Int = 1182

///|
pub let time_array_oid : Int = 1183

///|
pub let timestamp_array_oid : Int = 1115

///|
pub let timestamptz_array_oid : Int = 1185

///|
pub let interval_array_oid : Int = 1187

///|
pub let numeric_array_oid : Int = 1231

///|
pub let timetz_array_oid : Int = 1270

///|
pub let bit_array_oid : Int = 1561

///|
pub let varbit_array_oid : Int = 1563

///|
pub let record_array_oid : Int = 2287

///|
pub let uuid_array_oid : Int = 2951

///|
pub let tsvector_array_oid : Int = 3643

///|
pub let json_array_oid : Int = 199

///|
pub let jsonb_array_oid : Int = 3807

///|
pub let xml_array_oid : Int = 143

///|
pub let jsonpath_array_oid : Int = 4073

///|
pub let xid8_array_oid : Int = 271

///|
pub let line_array_oid : Int = 629

///|
pub let circle_array_oid : Int = 719

///|
pub let daterange_array_oid : Int = 3913

///|
pub let int4range_array_oid : Int = 3905

///|
pub let numrange_array_oid : Int = 3907

///|
pub let tsrange_array_oid : Int = 3909

///|
pub let tstzrange_array_oid : Int = 3911

///|
pub let int8range_array_oid : Int = 3927

///|
pub let int4multirange_array_oid : Int = 6150

///|
pub let nummultirange_array_oid : Int = 6151

///|
pub let tsmultirange_array_oid : Int = 6152

///|
pub let tstzmultirange_array_oid : Int = 6153

///|
pub let datemultirange_array_oid : Int = 6155

///|
pub let int8multirange_array_oid : Int = 6157

// ===========================================================================
// Type name constants — for use when referencing PG types by name
// ===========================================================================

///|
/// Base type names
pub let text_name : String = "text"

///|
pub let varchar_name : String = "varchar"

///|
pub let bpchar_name : String = "bpchar"

///|
pub let name_name : String = "name"

///|
pub let unknown_name : String = "unknown"

///|
pub let bool_name : String = "bool"

///|
pub let int8_name : String = "int8"

///|
pub let int2_name : String = "int2"

///|
pub let int4_name : String = "int4"

///|
pub let float4_name : String = "float4"

///|
pub let float8_name : String = "float8"

///|
pub let bytea_name : String = "bytea"

///|
pub let json_name : String = "json"

///|
pub let jsonb_name : String = "jsonb"

///|
pub let timestamp_name : String = "timestamp"

///|
pub let timestamptz_name : String = "timestamptz"

///|
pub let char_name : String = "char"

///|
pub let oid_name : String = "oid"

///|
pub let tid_name : String = "tid"

///|
pub let xid_name : String = "xid"

///|
pub let cid_name : String = "cid"

///|
pub let xml_name : String = "xml"

///|
pub let point_name : String = "point"

///|
pub let lseg_name : String = "lseg"

///|
pub let path_name : String = "path"

///|
pub let box_name : String = "box"

///|
pub let polygon_name : String = "polygon"

///|
pub let line_name : String = "line"

///|
pub let cidr_name : String = "cidr"

///|
pub let circle_name : String = "circle"

///|
pub let macaddr8_name : String = "macaddr8"

///|
pub let macaddr_name : String = "macaddr"

///|
pub let inet_name : String = "inet"

///|
pub let aclitem_name : String = "aclitem"

///|
pub let date_name : String = "date"

///|
pub let time_name : String = "time"

///|
pub let interval_name : String = "interval"

///|
pub let timetz_name : String = "timetz"

///|
pub let bit_name : String = "bit"

///|
pub let varbit_name : String = "varbit"

///|
pub let numeric_name : String = "numeric"

///|
pub let record_name : String = "record"

///|
pub let uuid_name : String = "uuid"

///|
pub let tsvector_name : String = "tsvector"

///|
pub let jsonpath_name : String = "jsonpath"

///|
pub let xid8_name : String = "xid8"

///|
/// Range type names
pub let int4range_name : String = "int4range"

///|
pub let numrange_name : String = "numrange"

///|
pub let tsrange_name : String = "tsrange"

///|
pub let tstzrange_name : String = "tstzrange"

///|
pub let daterange_name : String = "daterange"

///|
pub let int8range_name : String = "int8range"

///|
/// Multirange type names
pub let int4multirange_name : String = "int4multirange"

///|
pub let nummultirange_name : String = "nummultirange"

///|
pub let tsmultirange_name : String = "tsmultirange"

///|
pub let tstzmultirange_name : String = "tstzmultirange"

///|
pub let datemultirange_name : String = "datemultirange"

///|
pub let int8multirange_name : String = "int8multirange"

///|
/// Array type names (internal PG prefix convention: `_type`)
pub let _bool_name : String = "_bool"

///|
pub let _int4_name : String = "_int4"

///|
pub let _text_name : String = "_text"

///|
pub let _varchar_name : String = "_varchar"

///|
pub let _float4_name : String = "_float4"

///|
pub let _float8_name : String = "_float8"

///|
pub let _timestamp_name : String = "_timestamp"

///|
pub let _timestamptz_name : String = "_timestamptz"

///|
pub let _uuid_name : String = "_uuid"

///|
pub let _json_name : String = "_json"

///|
pub let _jsonb_name : String = "_jsonb"

///|
pub let _bytea_name : String = "_bytea"

///|
pub let _char_name : String = "_char"

///|
pub let _name_name : String = "_name"

///|
pub let _int2_name : String = "_int2"

///|
pub let _int8_name : String = "_int8"

///|
pub let _numeric_name : String = "_numeric"

///|
pub let _date_name : String = "_date"

///|
pub let _time_name : String = "_time"

///|
pub let _timetz_name : String = "_timetz"

///|
pub let _interval_name : String = "_interval"

///|
pub let _bit_name : String = "_bit"

///|
pub let _varbit_name : String = "_varbit"

///|
pub let _record_name : String = "_record"

///|
pub let _tid_name : String = "_tid"

///|
pub let _xid_name : String = "_xid"

///|
pub let _cid_name : String = "_cid"

///|
pub let _oid_name : String = "_oid"

///|
pub let _aclitem_name : String = "_aclitem"

///|
pub let _bpchar_name : String = "_bpchar"

///|
pub let _point_name : String = "_point"

///|
pub let _lseg_name : String = "_lseg"

///|
pub let _path_name : String = "_path"

///|
pub let _box_name : String = "_box"

///|
pub let _polygon_name : String = "_polygon"

///|
pub let _line_name : String = "_line"

///|
pub let _circle_name : String = "_circle"

///|
pub let _macaddr_name : String = "_macaddr"

///|
pub let _inet_name : String = "_inet"

///|
pub let _tsvector_name : String = "_tsvector"

///|
pub let _xml_name : String = "_xml"

///|
pub let _jsonpath_name : String = "_jsonpath"

///|
pub let _xid8_name : String = "_xid8"

///|
pub let _daterange_name : String = "_daterange"

///|
pub let _int4range_name : String = "_int4range"

///|
pub let _numrange_name : String = "_numrange"

///|
pub let _tsrange_name : String = "_tsrange"

///|
pub let _tstzrange_name : String = "_tstzrange"

///|
pub let _int8range_name : String = "_int8range"

///|
pub let _int4multirange_name : String = "_int4multirange"

///|
pub let _nummultirange_name : String = "_nummultirange"

///|
pub let _tsmultirange_name : String = "_tsmultirange"

///|
pub let _tstzmultirange_name : String = "_tstzmultirange"

///|
pub let _datemultirange_name : String = "_datemultirange"

///|
pub let _int8multirange_name : String = "_int8multirange"

// ===========================================================================
// information_schema.data_type name constants (dt_ prefix)
// ===========================================================================

///|
pub let dt_integer : String = "integer"

///|
pub let dt_bigint : String = "bigint"

///|
pub let dt_smallint : String = "smallint"

///|
pub let dt_boolean : String = "boolean"

///|
pub let dt_character_varying : String = "character varying"

///|
pub let dt_character : String = "character"

///|
pub let dt_double_precision : String = "double precision"

///|
pub let dt_real : String = "real"

///|
pub let dt_timestamp_with_time_zone : String = "timestamp with time zone"

///|
pub let dt_timestamp_without_time_zone : String = "timestamp without time zone"

///|
pub let dt_time_with_time_zone : String = "time with time zone"

///|
pub let dt_time_without_time_zone : String = "time without time zone"

///|
pub let dt_ARRAY : String = "ARRAY"

// ===========================================================================
// Default type map
// ===========================================================================

///|
/// Build the default type map with all common built-in PostgreSQL types.
/// Each type is registered with its codec.
fn build_default_map() -> TypeMap {
  let m = TypeMap::new()
    // Base types — text family
    .register(text_name, text_oid, text_codec)
    .register(varchar_name, varchar_oid, text_codec)
    .register(bpchar_name, bpchar_oid, text_codec)
    .register(name_name, name_oid, text_codec)
    .register(unknown_name, unknown_oid, text_codec)
    // Base types — typed codecs
    .register(bool_name, bool_oid, bool_codec)
    .register(int8_name, int8_oid, int8_codec)
    .register(int2_name, int2_oid, int2_codec)
    .register(int4_name, int4_oid, int4_codec)
    .register(float4_name, float4_oid, float4_codec)
    .register(float8_name, float8_oid, float8_codec)
    .register(bytea_name, bytea_oid, bytea_codec)
    .register(json_name, json_oid, json_codec)
    .register(jsonb_name, jsonb_oid, jsonb_codec)
    .register(timestamp_name, timestamp_oid, timestamp_codec)
    .register(timestamptz_name, timestamptz_oid, timestamptz_codec)
    // Base types — text fallback (not yet implemented as dedicated codecs)
    .register(char_name, char_oid, text_codec)
    .register(oid_name, oid_oid, text_codec)
    .register(tid_name, tid_oid, text_codec)
    .register(xid_name, xid_oid, text_codec)
    .register(cid_name, cid_oid, text_codec)
    .register(xml_name, xml_oid, text_codec)
    .register(point_name, point_oid, text_codec)
    .register(lseg_name, lseg_oid, text_codec)
    .register(path_name, path_oid, text_codec)
    .register(box_name, box_oid, text_codec)
    .register(polygon_name, polygon_oid, text_codec)
    .register(line_name, line_oid, text_codec)
    .register(cidr_name, cidr_oid, text_codec)
    .register(circle_name, circle_oid, text_codec)
    .register(macaddr8_name, macaddr8_oid, text_codec)
    .register(macaddr_name, macaddr_oid, text_codec)
    .register(inet_name, inet_oid, text_codec)
    .register(aclitem_name, aclitem_oid, text_codec)
    .register(date_name, date_oid, text_codec)
    .register(time_name, time_oid, text_codec)
    .register(interval_name, interval_oid, text_codec)
    .register(timetz_name, timetz_oid, text_codec)
    .register(bit_name, bit_oid, text_codec)
    .register(varbit_name, varbit_oid, text_codec)
    .register(numeric_name, numeric_oid, text_codec)
    .register(record_name, record_oid, text_codec)
    .register(uuid_name, uuid_oid, text_codec)
    .register(tsvector_name, tsvector_oid, text_codec)
    .register(jsonpath_name, jsonpath_oid, text_codec)
    .register(xid8_name, xid8_oid, text_codec)
    // Range types
    .register(int4range_name, int4range_oid, text_codec)
    .register(numrange_name, numrange_oid, text_codec)
    .register(tsrange_name, tsrange_oid, text_codec)
    .register(tstzrange_name, tstzrange_oid, text_codec)
    .register(daterange_name, daterange_oid, text_codec)
    .register(int8range_name, int8range_oid, text_codec)
    // Multirange types
    .register(int4multirange_name, int4multirange_oid, text_codec)
    .register(nummultirange_name, nummultirange_oid, text_codec)
    .register(tsmultirange_name, tsmultirange_oid, text_codec)
    .register(tstzmultirange_name, tstzmultirange_oid, text_codec)
    .register(datemultirange_name, datemultirange_oid, text_codec)
    .register(int8multirange_name, int8multirange_oid, text_codec)
  // Array types — all wired to element codecs
  m
  .register(
    "_bool",
    bool_array_oid,
    ArrayCodec::new(m.type_for_oid(bool_oid).unwrap()),
  )
  .register(
    "_int4",
    int4_array_oid,
    ArrayCodec::new(m.type_for_oid(int4_oid).unwrap()),
  )
  .register(
    "_text",
    text_array_oid,
    ArrayCodec::new(m.type_for_oid(text_oid).unwrap()),
  )
  .register(
    "_varchar",
    varchar_array_oid,
    ArrayCodec::new(m.type_for_oid(varchar_oid).unwrap()),
  )
  .register(
    "_float4",
    float4_array_oid,
    ArrayCodec::new(m.type_for_oid(float4_oid).unwrap()),
  )
  .register(
    "_float8",
    float8_array_oid,
    ArrayCodec::new(m.type_for_oid(float8_oid).unwrap()),
  )
  .register(
    "_timestamp",
    timestamp_array_oid,
    ArrayCodec::new(m.type_for_oid(timestamp_oid).unwrap()),
  )
  .register(
    "_timestamptz",
    timestamptz_array_oid,
    ArrayCodec::new(m.type_for_oid(timestamptz_oid).unwrap()),
  )
  .register(
    "_uuid",
    uuid_array_oid,
    ArrayCodec::new(m.type_for_oid(uuid_oid).unwrap()),
  )
  .register(
    "_json",
    json_array_oid,
    ArrayCodec::new(m.type_for_oid(json_oid).unwrap()),
  )
  .register(
    "_jsonb",
    jsonb_array_oid,
    ArrayCodec::new(m.type_for_oid(jsonb_oid).unwrap()),
  )
  .register(
    "_bytea",
    bytea_array_oid,
    ArrayCodec::new(m.type_for_oid(bytea_oid).unwrap()),
  )
  .register(
    "_char",
    char_array_oid,
    ArrayCodec::new(m.type_for_oid(char_oid).unwrap()),
  )
  .register(
    "_name",
    name_array_oid,
    ArrayCodec::new(m.type_for_oid(name_oid).unwrap()),
  )
  .register(
    "_int2",
    int2_array_oid,
    ArrayCodec::new(m.type_for_oid(int2_oid).unwrap()),
  )
  .register(
    "_int8",
    int8_array_oid,
    ArrayCodec::new(m.type_for_oid(int8_oid).unwrap()),
  )
  .register(
    "_numeric",
    numeric_array_oid,
    ArrayCodec::new(m.type_for_oid(numeric_oid).unwrap()),
  )
  .register(
    "_date",
    date_array_oid,
    ArrayCodec::new(m.type_for_oid(date_oid).unwrap()),
  )
  .register(
    "_time",
    time_array_oid,
    ArrayCodec::new(m.type_for_oid(time_oid).unwrap()),
  )
  .register(
    "_timetz",
    timetz_array_oid,
    ArrayCodec::new(m.type_for_oid(timetz_oid).unwrap()),
  )
  .register(
    "_interval",
    interval_array_oid,
    ArrayCodec::new(m.type_for_oid(interval_oid).unwrap()),
  )
  .register(
    "_bit",
    bit_array_oid,
    ArrayCodec::new(m.type_for_oid(bit_oid).unwrap()),
  )
  .register(
    "_varbit",
    varbit_array_oid,
    ArrayCodec::new(m.type_for_oid(varbit_oid).unwrap()),
  )
  .register(
    "_record",
    record_array_oid,
    ArrayCodec::new(m.type_for_oid(record_oid).unwrap()),
  )
  .register(
    "_tid",
    tid_array_oid,
    ArrayCodec::new(m.type_for_oid(tid_oid).unwrap()),
  )
  .register(
    "_xid",
    xid_array_oid,
    ArrayCodec::new(m.type_for_oid(xid_oid).unwrap()),
  )
  .register(
    "_cid",
    cid_array_oid,
    ArrayCodec::new(m.type_for_oid(cid_oid).unwrap()),
  )
  .register(
    "_oid",
    oid_array_oid,
    ArrayCodec::new(m.type_for_oid(oid_oid).unwrap()),
  )
  .register(
    "_aclitem",
    aclitem_array_oid,
    ArrayCodec::new(m.type_for_oid(aclitem_oid).unwrap()),
  )
  .register(
    "_bpchar",
    bpchar_array_oid,
    ArrayCodec::new(m.type_for_oid(bpchar_oid).unwrap()),
  )
  .register(
    "_point",
    point_array_oid,
    ArrayCodec::new(m.type_for_oid(point_oid).unwrap()),
  )
  .register(
    "_lseg",
    lseg_array_oid,
    ArrayCodec::new(m.type_for_oid(lseg_oid).unwrap()),
  )
  .register(
    "_path",
    path_array_oid,
    ArrayCodec::new(m.type_for_oid(path_oid).unwrap()),
  )
  .register(
    "_box",
    box_array_oid,
    ArrayCodec::new(m.type_for_oid(box_oid).unwrap()),
  )
  .register(
    "_polygon",
    polygon_array_oid,
    ArrayCodec::new(m.type_for_oid(polygon_oid).unwrap()),
  )
  .register(
    "_line",
    line_array_oid,
    ArrayCodec::new(m.type_for_oid(line_oid).unwrap()),
  )
  .register(
    "_circle",
    circle_array_oid,
    ArrayCodec::new(m.type_for_oid(circle_oid).unwrap()),
  )
  .register(
    "_macaddr",
    macaddr_array_oid,
    ArrayCodec::new(m.type_for_oid(macaddr_oid).unwrap()),
  )
  .register(
    "_inet",
    inet_array_oid,
    ArrayCodec::new(m.type_for_oid(inet_oid).unwrap()),
  )
  .register(
    "_tsvector",
    tsvector_array_oid,
    ArrayCodec::new(m.type_for_oid(tsvector_oid).unwrap()),
  )
  .register(
    "_xml",
    xml_array_oid,
    ArrayCodec::new(m.type_for_oid(xml_oid).unwrap()),
  )
  .register(
    "_jsonpath",
    jsonpath_array_oid,
    ArrayCodec::new(m.type_for_oid(jsonpath_oid).unwrap()),
  )
  .register(
    "_xid8",
    xid8_array_oid,
    ArrayCodec::new(m.type_for_oid(xid8_oid).unwrap()),
  )
  .register(
    "_daterange",
    daterange_array_oid,
    ArrayCodec::new(m.type_for_oid(daterange_oid).unwrap()),
  )
  .register(
    "_int4range",
    int4range_array_oid,
    ArrayCodec::new(m.type_for_oid(int4range_oid).unwrap()),
  )
  .register(
    "_numrange",
    numrange_array_oid,
    ArrayCodec::new(m.type_for_oid(numrange_oid).unwrap()),
  )
  .register(
    "_tsrange",
    tsrange_array_oid,
    ArrayCodec::new(m.type_for_oid(tsrange_oid).unwrap()),
  )
  .register(
    "_tstzrange",
    tstzrange_array_oid,
    ArrayCodec::new(m.type_for_oid(tstzrange_oid).unwrap()),
  )
  .register(
    "_int8range",
    int8range_array_oid,
    ArrayCodec::new(m.type_for_oid(int8range_oid).unwrap()),
  )
  .register(
    "_int4multirange",
    int4multirange_array_oid,
    ArrayCodec::new(m.type_for_oid(int4multirange_oid).unwrap()),
  )
  .register(
    "_nummultirange",
    nummultirange_array_oid,
    ArrayCodec::new(m.type_for_oid(nummultirange_oid).unwrap()),
  )
  .register(
    "_tsmultirange",
    tsmultirange_array_oid,
    ArrayCodec::new(m.type_for_oid(tsmultirange_oid).unwrap()),
  )
  .register(
    "_tstzmultirange",
    tstzmultirange_array_oid,
    ArrayCodec::new(m.type_for_oid(tstzmultirange_oid).unwrap()),
  )
  .register(
    "_datemultirange",
    datemultirange_array_oid,
    ArrayCodec::new(m.type_for_oid(datemultirange_oid).unwrap()),
  )
  .register(
    "_int8multirange",
    int8multirange_array_oid,
    ArrayCodec::new(m.type_for_oid(int8multirange_oid).unwrap()),
  )
  // information_schema.data_type aliases
  .register_data_type(dt_integer, int4_oid)
  .register_data_type(dt_bigint, int8_oid)
  .register_data_type(dt_smallint, int2_oid)
  .register_data_type(dt_boolean, bool_oid)
  .register_data_type(dt_character_varying, varchar_oid)
  .register_data_type(dt_character, bpchar_oid)
  .register_data_type(dt_double_precision, float8_oid)
  .register_data_type(dt_real, float4_oid)
  .register_data_type(dt_timestamp_with_time_zone, timestamptz_oid)
  .register_data_type(dt_timestamp_without_time_zone, timestamp_oid)
  .register_data_type(dt_time_with_time_zone, timetz_oid)
  .register_data_type(dt_time_without_time_zone, time_oid)
  .register_data_type(dt_ARRAY, record_oid)
}

///|
/// Default type map with all built-in PostgreSQL types.
pub let default_map : TypeMap = build_default_map()

///|
/// Look up the human-readable type name for a PostgreSQL OID in the default map.
/// Returns `"unknown"` when the OID is not registered.
pub fn oid_to_name(oid : Int) -> String {
  match default_map.type_for_oid(oid) {
    Some(t) => t.name
    None => "unknown"
  }
}

///|
/// Look up the OID for a canonical PG type name. Returns `0` for unknown names.
pub fn name_to_oid(name : String) -> Int {
  match default_map.type_for_name(name) {
    Some(t) => t.oid
    None => 0
  }
}

///|
/// Look up a type by `information_schema.data_type` name in the default map.
/// Returns `None` for unknown names.
pub fn type_for_data_type(name : String) -> Type? {
  default_map.type_for_data_type(name)
}
