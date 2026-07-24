# moonpg — remaining work

## 21. Codec-based Value encoding/decoding refactor ✅ DONE (2026-07-24)

- **Files:** `value/` (new), `pgtype/` (new), `conn.mbt`, `types.mbt`, `wire/raw_conn.mbt`, `wire/error.mbt`, `wire/backend_messages.mbt`
- **Done:**
  - `value/` package: `Value` (9 variants), `Format`, `ToValue` (single method), `FromValue` (single method), `Timestamp` struct, built-in impls for all types.
  - `pgtype/` package: `Codec` trait (`prefer_format`, `encode(Value)→Bytes?`, `decode(Bytes?)→Value`), `Type{name, oid, &Codec}`, `TypeMap` with `codec_for(oid)`, 12 codecs (Bool, Int2/4/8, Float4/8, Text, Bytea, JSON/JSONB, Timestamp/Timestamptz), ~90 OID constants, `default_map`.
  - `Row::get` uses `codec.decode(oid, format, bytes?)` → `FromValue::from_value(val)`.
  - `Connection::query/execute` uses `prepare()` → codec.encode per param OID → `execute_statement()`.
  - `result_formats` optional on `execute_statement`, synthesized from `stmt.fields[].format`.
  - Removed: `RawValue`, `FromRaw`, `build_params`, `default_encode`, `Value::to_raw()`, `Value::pg_type_name()`, old `ToValue::to_raw_value()`/`pg_type()`, `execute_params`.
  - Type compatibility: Bool accepts String, Int8 accepts Int, Float4/8 accept Int/Int64, JSON accepts String, Timestamp accepts String, Text accepts Json.
  - 281 tests pass (69 new codec/value tests, 18 old execute_params tests deleted).

## Critical fixes

These are bugs or crash paths in already-implemented features.

### 1. Fix SCRAM-SHA-256 authentication bug ✅ DONE (2026-07-15)
- Verified working — removed catch-all from test. All three auth methods (plain, MD5, SCRAM) connect successfully.

### 2. Binary-format decode for Json, Decimal, UUID (WON'T FIX)
- Text format is sufficient for these types; binary decode deferred unless needed.

### 3. Replace `abort()` with proper errors in config parser ✅ DONE (2026-07-15)
- **File:** `wire/config.mbt`
- **Done:** Three `abort()` calls in `parse_uri`, `scan_keyword`, `scan_quoted` replaced with `raise WireError::Parse(...)`. All intermediate functions (`scan_quoted`, `scan_value`, `scan_keyword`, `parse_kv`, `parse_uri`, `from_connstr`) now propagate `WireError`.

---

## High priority (essential for production use)

### 4. TLS/SSL support ✅ DONE (2026-07-15)
- **Files:** `wire/transport.mbt` (new), `wire/raw_conn.mbt`, `wire/moon.pkg`
- **Done:** `Transport` trait (`@io.Reader + @io.Writer + close`), `Stream` enum (`Plain(@socket.Tcp)` | `Tls(@tls.Tls)`), full SSL handshake in `connect_config`, `sslmode=prefer` fallback.
- **Also done (2026-07-17):** `sslrootcert`/`sslcert`/`sslkey` config parsing → `CustomPemFile` trust. Handles all sslmodes (`disable`, `allow`, `prefer`, `require`, `verify-ca`, `verify-full`). TLS shutdown deferred (PG clients don't need graceful shutdown).

### 5. Connection timeouts ✅ DONE (2026-07-15)
- **Files:** `wire/config.mbt`, `wire/raw_conn.mbt`
- **Done:**
  - `connect_timeout` — parsed from conn string (seconds), defaults to 0 (no timeout). Uses `@async.with_timeout` to wrap `Tcp::connect`.
  - `keepalives` / `keepalives_idle` / `keepalives_interval` / `keepalives_count` — parsed and passed to `Tcp::enable_keepalive` before SSL negotiation.
  - `statement_timeout` (2026-07-17) — sent as startup parameter so the server cancels long-running queries. No client-side read timeout needed.

### 6. Transaction isolation levels and options ✅ DONE (2026-07-16)
- **Files:** `tx.mbt`, `pool.mbt`, `tx_test.mbt`
- **Done:** `TxOptions` struct with `isolation_level` / `read_only` / `deferrable`. `TxBeginner::begin_tx` now takes optional `TxOptions`. Default `TxOptions` produces `BEGIN` (backward compatible). All three impls updated.

### 7. Connection health check / validation ✅ DONE (2026-07-16)
- **Files:** `pool.mbt`
- **Done:**
  - `PoolConfig.health_check` — when enabled, `acquire()` pings idle connections with `SELECT 1` before checkout.
  - `release()` now checks `max_lifetime_sec` and closes expired connections instead of recycling.

### 8. Send `application_name` in startup message ✅ DONE (2026-07-15)
- Done alongside TLS implementation.

---

## Medium priority

### 9. COPY protocol ✅ DONE (2026-07-16)
- **Files:** `wire/raw_conn.mbt`, `conn.mbt`, `integration_test.mbt`
- **Done:**
  - All COPY wire messages, receive dispatch.
  - `RawConn::begin_copy_in` / `RawConn::end_copy_in` — streaming phases, send_copy_data/send_copy_done/send_copy_fail.
  - `RawConn::copy_in(sql, Iter[String])` — accepts iterator, one row in memory.
  - `Connection::copy_in(sql, Iter[String])` — same, public API.
  - `CopyWriter` — high-level streaming: `begin_copy(table, columns)` → `write_row(Array[&ToValue])` → `finish()`.  Auto-generates SQL, encodes values (NULL→`\N`, backslash-escaped strings, hex bytea).

### 10. LISTEN / NOTIFY ✅ DONE (2026-07-16)
- **Files:** `wire/backend_messages.mbt`, `wire/raw_conn.mbt`, `conn.mbt`
- **Done:**
  - `NotificationResponse` backend message struct (pid, channel, payload), handled in `receive_inner()`.
  - `Connection::listen_and_recv(channel, q, group)` — spawns background receive loop on task group, pushes notifications to async queue. No polling, no array buffering — `receive()` → match `NotificationResponse` → `try_put(q)`.
  - `Connection::unlisten(channel)` / `Connection::notify(channel, payload?)`.
  - Cross-task usage: caller creates task group, `listen_and_recv` runs in bg, main body does `q.get()` → `spawn_bg(handler)` per notification.
- **Deferred:** `FunctionCallResponse` (`'V'`) — separate protocol feature, not needed for LISTEN/NOTIFY.

### 11. Savepoints
- **Files:** `tx.mbt`
- **What to do:**
  - Add `savepoint(name)` method to `Tx` trait: execute `SAVEPOINT name`.
  - Add `rollback_to(name)` method: execute `ROLLBACK TO SAVEPOINT name`.
  - Add `release(name)` method: execute `RELEASE SAVEPOINT name`.
  - Consider a `savepoint_func(tx, name, f)` helper: create savepoint, run `f`, rollback to savepoint on error, release on success.

### 12. Pool background maintenance ✅ DONE (2026-07-16)
- **Files:** `pool.mbt`
- **Done:**
  - `PoolConfig.maintenance_interval_sec` — configurable interval (0 = disabled, maintenance happens lazily).
  - `Pool.min_idle` / `Pool.idle_count` / `Pool.running` fields.
  - `Pool::idle()` — number of idle connections.
  - `Pool::maintain()` — one round: drain+filter expired idle conns, put good ones back, refill to `min_idle`.
  - `Pool::start_maintenance()` — background loop via `spawn_loop(no_wait=true)` with `@async.sleep` interval.
  - `Pool::close()` stops maintenance via `running` flag.
  - `idle_count` tracked through acquire/release/maintain/close.

### 13. Pool stats / monitoring ✅ DONE (2026-07-16)
- **Files:** `pool.mbt`
- **Done:**
  - `PoolStats` struct: `total_connections`, `idle_connections`, `active_connections`, `acquire_count`, `acquire_wait_count`, `acquire_wait_duration_ms`.
  - `Pool::stats()` — returns a `PoolStats` snapshot.
  - Counters tracked in `Pool.acquire()`: acquire count, wait count, cumulative wait duration.

### 14. Expose `close_statement` in public API ✅ DONE (2026-07-16)
- **Files:** `conn.mbt`
- **Done:** `Connection::deallocate(name)` — wraps `RawConn::close_statement`, raises `PgError` on failure.

### Connection property accessors ✅ DONE (2026-07-17)
- **Files:** `conn.mbt`
- **Done:** `Connection::backend_pid()`, `Connection::param(key)`, `Connection::is_closed()`.

---

## Low priority (nice to have)

### 15. Binary result-format integration tests ✅ DONE (2026-07-17)
- **Files:** `integration_test.mbt`, `value.mbt` (added `binary_raw()` helper)
- **Done:** Two integration tests (`binary_result_format_roundtrip`, `binary_result_format_nullable`) that use `RawConn::execute_params` with `result_formats=[1]`, verify column format codes, and decode values via `FromRaw` trait (Int, Int64, Double, Bool, String, Option[String]).

### 16. GSSAPI / SSPI authentication
- **What to do:** Implement Kerberos authentication for enterprise PG deployments. Requires GSSAPI bindings — significant scope. Lower priority since most deployments use password or cert-based auth.

### 17. NegotiateProtocolVersion support ✅ DONE (2026-07-17)
- **Files:** `wire/types.mbt`, `wire/backend_messages.mbt`, `wire/raw_conn.mbt`
- **Done:** `MSG_NEGOTIATE_PROTOCOL_VERSION` constant, `NegotiateProtocolVersion` struct + `Message` impl + `BackendMessage` variant, dispatch in `receive_inner()`, handled in startup loop. Since we send V3_2 (universally supported), the server will never send this in practice — future-proofing.

### 18. `target_session_attrs` support ✅ DONE (2026-07-17)
- **Files:** `wire/config.mbt`, `wire/raw_conn.mbt`
- **Done:** Parsed from conn string (values: `read-write`, `read-only`, `primary`, `standby`, `prefer-standby`, `any`). Post-connect validation checks `default_transaction_read_only` parameter status. `prefer-standby` treated as `any` (requires multi-host support).

### 19. Connection-level access to `RawConn` properties ✅ DONE (2026-07-17)
- **Files:** `conn.mbt`
- **Done:** `Connection::backend_pid()`, `Connection::param(key)`, `Connection::is_closed()`.

### 20. Row iteration via `Iter` trait ⏸️ DEFERRED
- **Why:** MoonBit's `Iter` trait requires synchronous value production, but row reading is async (network I/O). The existing `has_next()`/`get_row()` pull pattern already provides streaming access. Revisit when MoonBit stabilizes async iteration.

---

## Summary by effort estimate

| Priority | Item | Est. effort |
|---|---|---|
| 🔴 Critical | SCRAM-SHA-256 bug | Days (debugging) |
| 🔴 Critical | Binary decode Json/Decimal/UUID | Hours |
| 🔴 Critical | Config `abort()` → proper errors | Minutes |
| 🟠 High | TLS/SSL | ✅ Done |
| 🟠 High | Connection timeouts | ✅ Done |
| 🟠 High | Tx isolation levels | ✅ Done |
| 🟠 High | Health check / validation | ✅ Done |
| 🟠 High | `application_name` in startup | ✅ Done |
| 🟡 Medium | COPY protocol + streaming | ✅ Done |
| 🟡 Medium | LISTEN/NOTIFY | ✅ Done |
| 🟡 Medium | Savepoints | ⏸️ Deferred |
| 🟡 Medium | Pool maintenance loop | ✅ Done |
| 🟡 Medium | Pool stats | ✅ Done |
| 🟡 Medium | Public `deallocate()` | ✅ Done |
| 🟢 Low | Binary result integration tests | ✅ Done |
| 🟢 Low | GSSAPI/SSPI auth | ⏸️ Deferred |
| 🟢 Low | NegotiateProtocolVersion | ✅ Done |
| 🟢 Low | `target_session_attrs` | ✅ Done |
| 🟢 Low | Expose RawConn props on Connection | ✅ Done |
| 🟢 Low | Row iteration via `Iter` trait | ⏸️ Deferred |
