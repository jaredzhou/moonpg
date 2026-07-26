# 01 — Bare-minimum array support (MVP)

**What to build:** `int4[]`, `bool[]`, and simple `text[]` roundtrip end-to-end — a user can insert and query arrays of these three types through the normal `Row::get` flow.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] `Value::Array(Array[Value])` variant added to `value/value.mbt`, with `Eq`/`Debug` derive, and `to_string` representation
- [ ] `ArrayCodec` struct in `pgtype/array_codec.mbt` holding element `Type`, implementing the `Codec` trait
- [ ] Text format encoder that delegates to element codec for each element, joins with commas, wraps in `{...}`
- [ ] Basic text format parser (comma-split, no quoted-element support) — enough for `int`, `bool`, and simple `text` values
- [ ] NULL element handling: bare `NULL` in text → `Value::Null`, `None` on wire → `NULL` in text
- [ ] `ToValue` blanket impl for `Array[T]` where `T: ToValue` (rejects NULLs mid-array)
- [ ] `ToValue` blanket impl for `Array[T?]` where `T: ToValue` (allows None → Value::Null)
- [ ] `FromValue` blanket impl for `Array[T]` where `T: FromValue` (rejects Value::Null mid-array)
- [ ] `FromValue` blanket impl for `Array[T?]` where `T: FromValue` (accepts Value::Null → None)
- [ ] `_int4`, `_bool`, `_text` registered in `build_default_map()` with `ArrayCodec` instances wired to the correct element type
- [ ] Tests: roundtrip `{1,-5,NULL,42}` as `Array[Int?]`, `{t,f,t}` as `Array[Bool]`, `{hello,world}` as `Array[String]`
