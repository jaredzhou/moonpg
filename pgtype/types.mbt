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
// Default type map
// ===========================================================================

///|
/// Build the default type map with all common built-in PostgreSQL types.
/// Each type is registered with its codec.
fn build_default_map() -> TypeMap {
  TypeMap::new()
  // Base types — text family
  .register("text", text_oid, text_codec)
  .register("varchar", varchar_oid, text_codec)
  .register("bpchar", bpchar_oid, text_codec)
  .register("name", name_oid, text_codec)
  .register("unknown", unknown_oid, text_codec)
  // Base types — typed codecs
  .register("bool", bool_oid, bool_codec)
  .register("int8", int8_oid, int8_codec)
  .register("int2", int2_oid, int2_codec)
  .register("int4", int4_oid, int4_codec)
  .register("float4", float4_oid, float4_codec)
  .register("float8", float8_oid, float8_codec)
  .register("bytea", bytea_oid, bytea_codec)
  .register("json", json_oid, json_codec)
  .register("jsonb", jsonb_oid, jsonb_codec)
  .register("timestamp", timestamp_oid, timestamp_codec)
  .register("timestamptz", timestamptz_oid, timestamptz_codec)
  // Base types — text fallback (not yet implemented as dedicated codecs)
  .register("char", char_oid, text_codec)
  .register("oid", oid_oid, text_codec)
  .register("tid", tid_oid, text_codec)
  .register("xid", xid_oid, text_codec)
  .register("cid", cid_oid, text_codec)
  .register("xml", xml_oid, text_codec)
  .register("point", point_oid, text_codec)
  .register("lseg", lseg_oid, text_codec)
  .register("path", path_oid, text_codec)
  .register("box", box_oid, text_codec)
  .register("polygon", polygon_oid, text_codec)
  .register("line", line_oid, text_codec)
  .register("cidr", cidr_oid, text_codec)
  .register("circle", circle_oid, text_codec)
  .register("macaddr8", macaddr8_oid, text_codec)
  .register("macaddr", macaddr_oid, text_codec)
  .register("inet", inet_oid, text_codec)
  .register("aclitem", aclitem_oid, text_codec)
  .register("date", date_oid, text_codec)
  .register("time", time_oid, text_codec)
  .register("interval", interval_oid, text_codec)
  .register("timetz", timetz_oid, text_codec)
  .register("bit", bit_oid, text_codec)
  .register("varbit", varbit_oid, text_codec)
  .register("numeric", numeric_oid, text_codec)
  .register("record", record_oid, text_codec)
  .register("uuid", uuid_oid, text_codec)
  .register("tsvector", tsvector_oid, text_codec)
  .register("jsonpath", jsonpath_oid, text_codec)
  .register("xid8", xid8_oid, text_codec)
  // Range types
  .register("int4range", int4range_oid, text_codec)
  .register("numrange", numrange_oid, text_codec)
  .register("tsrange", tsrange_oid, text_codec)
  .register("tstzrange", tstzrange_oid, text_codec)
  .register("daterange", daterange_oid, text_codec)
  .register("int8range", int8range_oid, text_codec)
  // Multirange types
  .register("int4multirange", int4multirange_oid, text_codec)
  .register("nummultirange", nummultirange_oid, text_codec)
  .register("tsmultirange", tsmultirange_oid, text_codec)
  .register("tstzmultirange", tstzmultirange_oid, text_codec)
  .register("datemultirange", datemultirange_oid, text_codec)
  .register("int8multirange", int8multirange_oid, text_codec)
  // Array types
  .register("_bool", bool_array_oid, text_codec)
  .register("_bytea", bytea_array_oid, text_codec)
  .register("_char", char_array_oid, text_codec)
  .register("_name", name_array_oid, text_codec)
  .register("_int2", int2_array_oid, text_codec)
  .register("_int4", int4_array_oid, text_codec)
  .register("_text", text_array_oid, text_codec)
  .register("_tid", tid_array_oid, text_codec)
  .register("_xid", xid_array_oid, text_codec)
  .register("_cid", cid_array_oid, text_codec)
  .register("_bpchar", bpchar_array_oid, text_codec)
  .register("_varchar", varchar_array_oid, text_codec)
  .register("_int8", int8_array_oid, text_codec)
  .register("_point", point_array_oid, text_codec)
  .register("_lseg", lseg_array_oid, text_codec)
  .register("_path", path_array_oid, text_codec)
  .register("_box", box_array_oid, text_codec)
  .register("_float4", float4_array_oid, text_codec)
  .register("_float8", float8_array_oid, text_codec)
  .register("_polygon", polygon_array_oid, text_codec)
  .register("_oid", oid_array_oid, text_codec)
  .register("_aclitem", aclitem_array_oid, text_codec)
  .register("_macaddr", macaddr_array_oid, text_codec)
  .register("_inet", inet_array_oid, text_codec)
  .register("_date", date_array_oid, text_codec)
  .register("_time", time_array_oid, text_codec)
  .register("_timestamp", timestamp_array_oid, text_codec)
  .register("_timestamptz", timestamptz_array_oid, text_codec)
  .register("_interval", interval_array_oid, text_codec)
  .register("_numeric", numeric_array_oid, text_codec)
  .register("_timetz", timetz_array_oid, text_codec)
  .register("_bit", bit_array_oid, text_codec)
  .register("_varbit", varbit_array_oid, text_codec)
  .register("_record", record_array_oid, text_codec)
  .register("_uuid", uuid_array_oid, text_codec)
  .register("_tsvector", tsvector_array_oid, text_codec)
  .register("_json", json_array_oid, text_codec)
  .register("_jsonb", jsonb_array_oid, text_codec)
  .register("_xml", xml_array_oid, text_codec)
  .register("_jsonpath", jsonpath_array_oid, text_codec)
  .register("_xid8", xid8_array_oid, text_codec)
  .register("_line", line_array_oid, text_codec)
  .register("_circle", circle_array_oid, text_codec)
  .register("_daterange", daterange_array_oid, text_codec)
  .register("_int4range", int4range_array_oid, text_codec)
  .register("_numrange", numrange_array_oid, text_codec)
  .register("_tsrange", tsrange_array_oid, text_codec)
  .register("_tstzrange", tstzrange_array_oid, text_codec)
  .register("_int8range", int8range_array_oid, text_codec)
  .register("_int4multirange", int4multirange_array_oid, text_codec)
  .register("_nummultirange", nummultirange_array_oid, text_codec)
  .register("_tsmultirange", tsmultirange_array_oid, text_codec)
  .register("_tstzmultirange", tstzmultirange_array_oid, text_codec)
  .register("_datemultirange", datemultirange_array_oid, text_codec)
  .register("_int8multirange", int8multirange_array_oid, text_codec)
  // information_schema.data_type aliases
  .register_data_type("integer", int4_oid)
  .register_data_type("bigint", int8_oid)
  .register_data_type("smallint", int2_oid)
  .register_data_type("boolean", bool_oid)
  .register_data_type("character varying", varchar_oid)
  .register_data_type("character", bpchar_oid)
  .register_data_type("double precision", float8_oid)
  .register_data_type("real", float4_oid)
  .register_data_type("timestamp with time zone", timestamptz_oid)
  .register_data_type("timestamp without time zone", timestamp_oid)
  .register_data_type("time with time zone", timetz_oid)
  .register_data_type("time without time zone", time_oid)
  .register_data_type("ARRAY", record_oid)
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
