# 02 — Quoted-element parser

**What to build:** Robust text array parsing that correctly handles quoted elements with embedded commas, braces, double quotes, and backslash escapes — so string arrays containing special characters roundtrip correctly.

**Blocked by:** 01 — Bare-minimum array support (MVP)

**Status:** ready-for-agent

- [ ] Full parser upgrade in `ArrayCodec`: detect `"`-quoted elements, handle `\"` and `\\` escaping
- [ ] Bare `NULL` vs `"NULL"` distinction: unquoted → SQL NULL, quoted → literal string `"NULL"`
- [ ] Register `_varchar`, `_json`, `_jsonb`, `_uuid`, `_timestamp`, `_timestamptz`, `_float4`, `_float8` with `ArrayCodec`
- [ ] Tests: `{"hello, world","say \"hi\""}`, `{NULL,"NULL"}`, `{"{\"a\":1}"}` (json array), `{2024-01-01 12:00:00,2024-06-15 00:00:00}` (timestamp array)
