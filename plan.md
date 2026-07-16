# moonpg — remaining work

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
- **Remaining:** `sslrootcert` config for custom CA certs, TLS shutdown before close.

### 5. Connection timeouts ✅ DONE (2026-07-15)
- **Files:** `wire/config.mbt`, `wire/raw_conn.mbt`
- **Done:**
  - `connect_timeout` — parsed from conn string (seconds), defaults to 0 (no timeout). Uses `@async.with_timeout` to wrap `Tcp::connect`.
  - `keepalives` / `keepalives_idle` / `keepalives_interval` / `keepalives_count` — parsed and passed to `Tcp::enable_keepalive` before SSL negotiation.
- **Remaining:** Read/write socket timeouts (PG protocol has built-in query timeout via `statement_timeout` on server side; client-side read timeout adds complexity for long-running queries).

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
- **Files:** `wire/frontend_messages.mbt`, `wire/backend_messages.mbt`, `wire/raw_conn.mbt`, `wire/types.mbt`, `conn.mbt`, `integration_test.mbt`
- **Done:** All COPY wire messages (CopyData/CopyDone/CopyFail frontend, CopyInResponse/CopyOutResponse/CopyBothResponse/CopyData/CopyDone backend), receive dispatch, RawConn::copy_in + send_copy_data/send_copy_done/send_copy_fail, Connection::copy_in.
- **Note:** High-level API (`copy_in`/`copy_out`) may need refinement for streaming use cases.

### 10. LISTEN / NOTIFY
- **Files:** `wire/backend_messages.mbt`, `wire/raw_conn.mbt`
- **Current state:** `MSG_NOTIFICATION_RESPONSE` constant is defined but no `NotificationResponse` message struct exists; notification messages are silently dropped by `Unknown`.
- **What to do:**
  1. Add `NotificationResponse` backend message struct (pid, channel, payload).
  2. Add `FunctionCallResponse` backend message struct (fid, result format, columns, data rows).
  3. Handle both in `receive_inner()`.
  4. Add notification callback mechanism: `RawConn::on_notification(fn(NotificationResponse) -> Unit)` or a channel-based approach.
  5. Add `Listen`/`Unlisten`/`Notify` as convenience methods (or just document using `execute("LISTEN foo")` and reading notifications via the callback).

### 11. Savepoints
- **Files:** `tx.mbt`
- **What to do:**
  - Add `savepoint(name)` method to `Tx` trait: execute `SAVEPOINT name`.
  - Add `rollback_to(name)` method: execute `ROLLBACK TO SAVEPOINT name`.
  - Add `release(name)` method: execute `RELEASE SAVEPOINT name`.
  - Consider a `savepoint_func(tx, name, f)` helper: create savepoint, run `f`, rollback to savepoint on error, release on success.

### 12. Pool background maintenance
- **Files:** `pool.mbt`
- **Current state:** `min_idle` is only enforced at pool construction time. Idle connections that expire are not replaced.
- **What to do:**
  - Add a background task that periodically:
    - Removes idle connections exceeding `max_idle_sec`.
    - Removes connections exceeding `max_lifetime_sec`.
    - Creates new connections if idle count < `min_idle`.
  - This requires careful design in the async model — likely a loop with `sleep` intervals.

### 13. Pool stats / monitoring
- **Files:** `pool.mbt`
- **What to do:**
  - Add counters: `total_connections`, `idle_connections`, `active_connections`, `acquire_count`, `acquire_wait_count`, `acquire_wait_duration`.
  - Expose via `Pool::stats()` → `PoolStats` struct.
  - Optionally emit events/hooks for lifecycle transitions (connect, disconnect, acquire, release).

### 14. Expose `close_statement` in public API
- **Files:** `conn.mbt` (Connection API), `wire/raw_conn.mbt` (already implemented at wire level)
- **Current state:** `RawConn::close_statement(name)` exists but is not exposed on `Connection` or `QueryExecutor`.
- **What to do:** Add `deallocate(name)` to `Connection` (and optionally to `QueryExecutor`). Sync + handle CloseComplete.

---

## Low priority (nice to have)

### 15. Binary result-format integration tests
- **What to do:** Add integration tests that explicitly request binary result format (format code 1 in Bind message) and verify correct round-trips for all supported types.

### 16. GSSAPI / SSPI authentication
- **What to do:** Implement Kerberos authentication for enterprise PG deployments. Requires GSSAPI bindings — significant scope. Lower priority since most deployments use password or cert-based auth.

### 17. NegotiateProtocolVersion support
- **Wire type byte:** `'v'`
- **What to do:** PG 17+ sends this when the client requests a newer protocol version than the server supports. Implement the negotiation handshake to allow future protocol version upgrades.

### 18. `target_session_attrs` support
- **What to do:** Parse `target_session_attrs` (read-write, read-only, primary, standby, prefer-standby, any). After connect, check `default_transaction_read_only` and/or `in_hot_standby` parameter status to verify the connected server matches the requested mode.

### 19. Connection-level access to `RawConn` properties
- **What to do:** Expose `Connection::backend_pid()`, `Connection::param(key)`, `Connection::is_closed()` to match what `RawConn` already provides.

### 20. Row iteration via `Iter` trait
- **What to do:** Implement MoonBit's `Iter` trait on result readers so users can use `for row in rows { ... }` syntax (once MoonBit's iteration story stabilizes).

---

## Summary by effort estimate

| Priority | Item | Est. effort |
|---|---|---|
| 🔴 Critical | SCRAM-SHA-256 bug | Days (debugging) |
| 🔴 Critical | Binary decode Json/Decimal/UUID | Hours |
| 🔴 Critical | Config `abort()` → proper errors | Minutes |
| 🟠 High | TLS/SSL | Large (depends on MoonBit TLS ecosystem) |
| 🟠 High | Connection timeouts | Medium |
| 🟠 High | Tx isolation levels | Small |
| 🟠 High | Health check / validation | Small |
| 🟠 High | `application_name` in startup | Trivial |
| 🟡 Medium | COPY protocol | Large |
| 🟡 Medium | LISTEN/NOTIFY | Medium |
| 🟡 Medium | Savepoints | Small |
| 🟡 Medium | Pool maintenance loop | Medium |
| 🟡 Medium | Pool stats | Small |
| 🟡 Medium | Public `deallocate()` | Small |
| 🟢 Low | Binary result integration tests | Small |
| 🟢 Low | GSSAPI/SSPI auth | Large |
| 🟢 Low | NegotiateProtocolVersion | Small |
| 🟢 Low | `target_session_attrs` | Small |
| 🟢 Low | Expose RawConn props on Connection | Trivial |
| 🟢 Low | Row iteration via `Iter` trait | Small |
