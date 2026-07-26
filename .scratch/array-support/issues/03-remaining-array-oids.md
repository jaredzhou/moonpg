# 03 — Remaining array OIDs

**What to build:** Every built-in PostgreSQL array type registered in `TypeMap` with a proper `ArrayCodec` instance, so the driver correctly handles any array column a server might return.

**Blocked by:** 02 — Quoted-element parser

**Status:** ready-for-agent

- [ ] Register all remaining array OIDs from `pgtype/types.mbt` (those currently using `text_codec` fallback) with proper `ArrayCodec` instances
- [ ] Includes: `_int2`, `_int8`, `_numeric`, `_bytea`, `_name`, `_char`, `_bpchar`, `_date`, `_time`, `_timetz`, `_interval`, `_bit`, `_varbit`, `_uuid`, `_xml`, `_jsonpath`, `_tsvector`, `_oid`, `_tid`, `_xid`, `_cid`, `_inet`, `_cidr`, `_macaddr`, `_macaddr8`, `_point`, `_lseg`, `_path`, `_box`, `_polygon`, `_line`, `_circle`, `_aclitem`, `_xid8`, `_record`
- [ ] Range and multirange array types: `_int4range`, `_numrange`, `_tsrange`, `_tstzrange`, `_daterange`, `_int8range`, and multirange equivalents
- [ ] Tests: smoke test on a few representative types to confirm correct codec wiring (no comprehensive per-type coverage needed)
