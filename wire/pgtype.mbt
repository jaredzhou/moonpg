///|
/// In-memory PostgreSQL type registry — mirrors pgx's `pgtype.Map`.
/// Stores OID ↔ name mappings so we never query `pg_type` at runtime.
/// No Codec — just the type metadata. Codec support can be layered on later.

///|
/// A registered PostgreSQL data type.
pub(all) struct Type {
  name : String
  oid : Int
}

///|
/// Registry of PostgreSQL type OID ↔ name mappings.
pub(all) struct TypeMap {
  oid_to_type : @hashmap.HashMap[Int, Type]
  name_to_type : @hashmap.HashMap[String, Type]
}

///|
fn new_type(name : String, oid : Int) -> Type {
  Type::{ name, oid }
}

///|
fn TypeMap::new() -> TypeMap {
  {
    oid_to_type: @hashmap.HashMap([], capacity=200),
    name_to_type: @hashmap.HashMap([], capacity=200),
  }
}

///|
fn TypeMap::register(self : TypeMap, name : String, oid : Int) -> TypeMap {
  let t = new_type(name, oid)
  // Only set oid_to_type on first registration — keeps the canonical PG name
  match self.oid_to_type.get(oid) {
    None => self.oid_to_type.set(oid, Type::{ ..t })
    Some(_) => ()
  }
  self.name_to_type.set(name, Type::{ ..t })
  self
}

///|
/// Look up a type by OID. Returns `None` for unknown OIDs.
pub fn TypeMap::type_for_oid(self : TypeMap, oid : Int) -> Type? {
  self.oid_to_type.get(oid)
}

///|
/// Look up a type by name. Returns `None` for unknown names.
pub fn TypeMap::type_for_name(self : TypeMap, name : String) -> Type? {
  self.name_to_type.get(name)
}

// ---------------------------------------------------------------------------
// OID constants — for compile-time reference (e.g. @wire.int4_oid)
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Default type map — built from the constants above
// ---------------------------------------------------------------------------

///|
/// Build the default type map with all common built-in PostgreSQL types.
fn build_default_map() -> TypeMap {
  TypeMap::new()
  // Base types
  .register("bool", bool_oid)
  .register("bytea", bytea_oid)
  .register("char", char_oid)
  .register("name", name_oid)
  .register("int8", int8_oid)
  .register("int2", int2_oid)
  .register("int4", int4_oid)
  .register("text", text_oid)
  .register("oid", oid_oid)
  .register("tid", tid_oid)
  .register("xid", xid_oid)
  .register("cid", cid_oid)
  .register("json", json_oid)
  .register("xml", xml_oid)
  .register("point", point_oid)
  .register("lseg", lseg_oid)
  .register("path", path_oid)
  .register("box", box_oid)
  .register("polygon", polygon_oid)
  .register("line", line_oid)
  .register("cidr", cidr_oid)
  .register("float4", float4_oid)
  .register("float8", float8_oid)
  .register("unknown", unknown_oid)
  .register("circle", circle_oid)
  .register("macaddr8", macaddr8_oid)
  .register("macaddr", macaddr_oid)
  .register("inet", inet_oid)
  .register("aclitem", aclitem_oid)
  .register("bpchar", bpchar_oid)
  .register("varchar", varchar_oid)
  .register("date", date_oid)
  .register("time", time_oid)
  .register("timestamp", timestamp_oid)
  .register("timestamptz", timestamptz_oid)
  .register("interval", interval_oid)
  .register("timetz", timetz_oid)
  .register("bit", bit_oid)
  .register("varbit", varbit_oid)
  .register("numeric", numeric_oid)
  .register("record", record_oid)
  .register("uuid", uuid_oid)
  .register("tsvector", tsvector_oid)
  .register("jsonb", jsonb_oid)
  .register("jsonpath", jsonpath_oid)
  .register("xid8", xid8_oid)
  // Range types
  .register("int4range", int4range_oid)
  .register("numrange", numrange_oid)
  .register("tsrange", tsrange_oid)
  .register("tstzrange", tstzrange_oid)
  .register("daterange", daterange_oid)
  .register("int8range", int8range_oid)
  // Multirange types
  .register("int4multirange", int4multirange_oid)
  .register("nummultirange", nummultirange_oid)
  .register("tsmultirange", tsmultirange_oid)
  .register("tstzmultirange", tstzmultirange_oid)
  .register("datemultirange", datemultirange_oid)
  .register("int8multirange", int8multirange_oid)
  // Array types
  .register("_bool", bool_array_oid)
  .register("_bytea", bytea_array_oid)
  .register("_char", char_array_oid)
  .register("_name", name_array_oid)
  .register("_int2", int2_array_oid)
  .register("_int4", int4_array_oid)
  .register("_text", text_array_oid)
  .register("_tid", tid_array_oid)
  .register("_xid", xid_array_oid)
  .register("_cid", cid_array_oid)
  .register("_bpchar", bpchar_array_oid)
  .register("_varchar", varchar_array_oid)
  .register("_int8", int8_array_oid)
  .register("_point", point_array_oid)
  .register("_lseg", lseg_array_oid)
  .register("_path", path_array_oid)
  .register("_box", box_array_oid)
  .register("_float4", float4_array_oid)
  .register("_float8", float8_array_oid)
  .register("_polygon", polygon_array_oid)
  .register("_oid", oid_array_oid)
  .register("_aclitem", aclitem_array_oid)
  .register("_macaddr", macaddr_array_oid)
  .register("_inet", inet_array_oid)
  .register("_date", date_array_oid)
  .register("_time", time_array_oid)
  .register("_timestamp", timestamp_array_oid)
  .register("_timestamptz", timestamptz_array_oid)
  .register("_interval", interval_array_oid)
  .register("_numeric", numeric_array_oid)
  .register("_timetz", timetz_array_oid)
  .register("_bit", bit_array_oid)
  .register("_varbit", varbit_array_oid)
  .register("_record", record_array_oid)
  .register("_uuid", uuid_array_oid)
  .register("_tsvector", tsvector_array_oid)
  .register("_json", json_array_oid)
  .register("_jsonb", jsonb_array_oid)
  .register("_xml", xml_array_oid)
  .register("_jsonpath", jsonpath_array_oid)
  .register("_xid8", xid8_array_oid)
  .register("_line", line_array_oid)
  .register("_circle", circle_array_oid)
  .register("_daterange", daterange_array_oid)
  .register("_int4range", int4range_array_oid)
  .register("_numrange", numrange_array_oid)
  .register("_tsrange", tsrange_array_oid)
  .register("_tstzrange", tstzrange_array_oid)
  .register("_int8range", int8range_array_oid)
  .register("_int4multirange", int4multirange_array_oid)
  .register("_nummultirange", nummultirange_array_oid)
  .register("_tsmultirange", tsmultirange_array_oid)
  .register("_tstzmultirange", tstzmultirange_array_oid)
  .register("_datemultirange", datemultirange_array_oid)
  .register("_int8multirange", int8multirange_array_oid)
  // information_schema standard SQL names — same OIDs, different names
  .register("integer", int4_oid)
  .register("bigint", int8_oid)
  .register("smallint", int2_oid)
  .register("boolean", bool_oid)
  .register("character varying", varchar_oid)
  .register("character", bpchar_oid)
  .register("double precision", float8_oid)
  .register("real", float4_oid)
  .register("timestamp with time zone", timestamptz_oid)
  .register("timestamp without time zone", timestamp_oid)
  .register("time with time zone", timetz_oid)
  .register("time without time zone", time_oid)
  .register("ARRAY", record_oid)
}

///|
/// Lazily-initialised default type map.
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
/// Look up the OID for a type name in the default map.
/// Returns `0` for unknown names (0 is not a valid PG OID).
pub fn name_to_oid(name : String) -> Int {
  match default_map.type_for_name(name) {
    Some(t) => t.oid
    None => 0
  }
}

///|
test "type_map_by_oid" {
  match default_map.type_for_oid(23) {
    Some(t) => {
      assert_eq(t.name, "int4")
      assert_eq(t.oid, 23)
    }
    None => fail("expected int4 type")
  }
  assert_true(default_map.type_for_oid(99999) is None)
}

///|
test "type_map_by_name" {
  match default_map.type_for_name("text") {
    Some(t) => assert_eq(t.oid, 25)
    None => fail("expected text type")
  }
}

///|
test "oid_to_name_common" {
  assert_eq(oid_to_name(23), "int4")
  assert_eq(oid_to_name(25), "text")
  assert_eq(oid_to_name(16), "bool")
  assert_eq(oid_to_name(701), "float8")
  assert_eq(oid_to_name(1700), "numeric")
  assert_eq(oid_to_name(3802), "jsonb")
  assert_eq(oid_to_name(99999), "unknown")
}

///|
test "oid_to_name_array" {
  assert_eq(oid_to_name(1007), "_int4")
  assert_eq(oid_to_name(1009), "_text")
  assert_eq(oid_to_name(1016), "_int8")
}

///|
test "oid_to_name_range" {
  assert_eq(oid_to_name(3904), "int4range")
  assert_eq(oid_to_name(3912), "daterange")
}

///|
test "information_schema_aliases" {
  // info schema names resolve to same OIDs as PG internal names
  assert_eq(name_to_oid("integer"), 23)
  assert_eq(name_to_oid("bigint"), 20)
  assert_eq(name_to_oid("smallint"), 21)
  assert_eq(name_to_oid("boolean"), 16)
  assert_eq(name_to_oid("character varying"), 1043)
  assert_eq(name_to_oid("double precision"), 701)
  assert_eq(name_to_oid("real"), 700)
  assert_eq(name_to_oid("timestamp with time zone"), 1184)
  assert_eq(name_to_oid("timestamp without time zone"), 1114)
  // canonical PG names still resolve via oid_to_name
  assert_eq(oid_to_name(23), "int4")
  assert_eq(oid_to_name(1184), "timestamptz")
}
