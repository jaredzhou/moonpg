# moonpg architecture

moonpg is a pure-MoonBit PostgreSQL client that speaks the [PostgreSQL wire
protocol (v3)](https://www.postgresql.org/docs/current/protocol.html) directly
over TCP.  There are zero C dependencies — no libpq, no native stubs.

## Layer diagram

```
                   ┌──────────────────────────────────┐
                   │  conn.mbt   pool.mbt   tx.mbt    │  ← public API
                   │  Connection  Pool  DbTx           │
                   │  Rows trait  QueryExecutor trait  │
                   └──────────────┬───────────────────┘
                   ┌──────────────┴───────────────────┐
                   │  value.mbt   types.mbt           │  ← encode / decode
                   │  Value  RawValue  FromRaw        │
                   │  ToValue  default_encode         │
                   └──────────────┬───────────────────┘
                   ┌──────────────┴───────────────────┐
                   │  wire/                           │  ← wire protocol
                   │  raw_conn.mbt  result_reader.mbt  │
                   │  frontend_messages.mbt            │
                   │  backend_messages.mbt             │
                   │  config.mbt  auth_md5 / auth_scram│
                   └──────────────┬───────────────────┘
                   ┌──────────────┴───────────────────┐
                   │  moonbitlang/async                │  ← platform
                   │  @socket.Tcp  @async.all          │
                   └──────────────────────────────────┘
```

## Module walkthrough

### `wire/` — PostgreSQL wire protocol

The lowest layer.  Communicates with the server via TCP, handles
startup, authentication, and message framing.

| File | Purpose |
|---|---|
| `raw_conn.mbt` | Core connection: TCP connect, SSL negotiation, startup, authentication handshake, `send`/`receive` message framing, `simple_query`, `execute_params` (extended query), lock/unlock lifecycle, cancel request. |
| `result_reader.mbt` | Pull-based result-set reader.  Consumes `DataRow` / `CommandComplete` / `ReadyForQuery` messages.  Supports `has_next()` + `data_row()` streaming and `read()` (eager collect). |
| `config.mbt` | Connection-string parser.  Supports both URI (`postgres://...`) and key-value (`host=... port=...`) formats. |
| `frontend_messages.mbt` | All client→server messages: `StartupMessage`, `Query`, `Parse`, `Bind`, `Execute`, `Describe`, `Close`, `Sync`, `PasswordMessage`, `SASLInitialResponse`, `SASLResponse`, `Terminate`, `Flush`. |
| `backend_messages.mbt` | All server→client messages: `Authentication*`, `BackendKeyData`, `ReadyForQuery`, `RowDescription`, `DataRow`, `CommandComplete`, `ErrorResponse`, `NoticeResponse`, `ParameterStatus`, etc. |
| `auth_md5.mbt` | MD5 password authentication (`md5` + salt). |
| `auth_scram.mbt` | SCRAM-SHA-256 authentication. |
| `error.mbt` | `WireError` type hierarchy (`Connect`, `Auth`, `Parse`, `IO`, `InvalidMessage`, `PgServer`). |
| `bytes_mut.mbt` | Mutable byte buffer for message encoding. |
| `read_util.mbt` | Pattern-matching helpers for decoding binary payloads (`i32be`, `u32be`, etc.). |
| `types.mbt` | Shared wire-level types: `CommandTag`, `TransactionStatus`. |

### `value.mbt` — Value encoding / decoding

- `Value` enum: `Null`, `Bool`, `Int`, `Int64`, `Float`, `String`, `Bytes`.
- `RawValue` enum: `Null` | `Bytes(Format, Bytes)` — what comes back from a result cell.
- `ToValue` trait: convert MoonBit types → `Value` for parameter binding.
- `FromRaw` trait: decode `RawValue` → MoonBit type.
- `default_encode()`, `build_params()`: encode `Value[]` → `(Bytes?[], Int[])` for the wire.
- Binary encode/decode helpers for `int4`, `int8`, `float8`, `bool`.

### `types.mbt` — Type impls

- `ToValue` / `FromRaw` impls for `Int`, `Int64`, `Double`, `Bool`, `String`, `Bytes`, `Json`, `Decimal`, `UUID`, `Timestamp`, and `Option[T]` (nullable).
- `Timestamp` struct: Unix-epoch microseconds with PG text/binary round-trip.

### `conn.mbt` — Connection & query API (public)

- `Connection` — wraps a wire-level `RawConn`.  Constructed via `connect(conninfo)`.
- `Rows` trait — polymorphic row reader interface:
  - `has_next()` — true if a row is pending.
  - `get_row()` — decode and return the next `Row`.
  - `columns()` — column metadata.
  - `close()` — drain remaining rows and release resources.
- `ConnRows` — `Rows` impl backed by a bare-connection `ResultReader`.
- `QueryExecutor` trait — `query()`, `query_one()`, `execute()`.
  - Implemented by `Connection`, `DbTx`, `Pool`, `PoolDbTx`.
- `Row` — snapshot of one result row (values + column descriptions).
- `ExecResult` — execution result with `affected_rows()`.
- `PgError` — public error type (`ConnectionError`, `QueryError`, `NoRows`).

### `pool.mbt` — Connection pool

- `Pool` — holds an unbounded `@aqueue.Queue` of idle `Connection`s and a
  `Ref[Int]` counter for total connections.
- `PoolConfig` — `conninfo`, `max_conns`, `min_idle`, `max_idle_sec`, `max_lifetime_sec`.
- `Pool::acquire()` — try idle queue first; if empty and below max, create new;
  if at max, block on `queue.get()`.
- `PoolConn` — a checked-out connection.  `release()` returns it to the idle
  queue; `close()` destroys it (decrements total).
- `PoolRows` — `Rows` impl that releases the `PoolConn` back to the pool on `close()`.
- `Pool` implements `QueryExecutor` — auto-acquire, delegate, auto-release (or
  close on error).
- `PoolDbTx` — transaction from a pooled connection; `commit()` / `rollback()`
  releases the connection.

### `tx.mbt` — Transactions

- `Tx` trait — `commit()` / `rollback()` on top of `QueryExecutor`.
- `TxBeginner` trait — `begin_tx()` → `DbTx`.
- `DbTx` — concrete transaction wrapping a `Connection` (and optionally a `Pool`
  for return-on-commit/rollback).
- `begin_func(tx, f)` — execute `f(tx)`, commit on success, rollback on error.

## Two query protocols

### Simple query

Used when `params` is absent.  Sends a single `Query` message; the server
responds with `RowDescription` + `DataRow`* + `CommandComplete` +
`ReadyForQuery`.  `simple_query()` in `raw_conn.mbt` runs this loop.

### Extended query

Used for parameterised queries (`params=[...]`).  Sends a pipeline:
`Parse` → `Bind` → `Describe(Portal)` → `Execute` → `Sync`.  The
server responds with `ParseComplete` → `BindComplete` →
`RowDescription|NoData` → `DataRow`* → `CommandComplete` →
`ReadyForQuery`.  `execute_params()` in `raw_conn.mbt` orchestrates
this.

## Async model

moonpg is built on `moonbitlang/async`, a single-threaded cooperative
runtime.  Each connection is an independent TCP socket; when one
connection blocks waiting for server data, the runtime switches to
other ready tasks.  This means:

- Multiple connections can run queries **concurrently** — a `pg_sleep(2)`
  on connection A does not block `SELECT 1` on connection B.
- The pool can **create new connections while others are busy**.
- No threads, no locks — just `@aqueue.Queue` and `Ref[Int]` for state.

## Data flow: a parameterised INSERT

```
User code                      conn.mbt               wire/                  PostgreSQL
─────────                      ────────               ─────                  ──────────
conn.execute("INSERT ...",    │                      │                      │
  params=[42, "x", true])     │                      │                      │
                               │ build_params()       │                      │
                               │ 42→"42", true→"t"    │                      │
                               │                      │                      │
                               │ execute_params() ────→ Parse ──────────────→
                               │                      → Bind  ──────────────→
                               │                      → Describe(Portal) ───→
                               │                      → Execute ────────────→
                               │                      → Sync ───────────────→
                               │                      │                      │
                               │                      ← ParseComplete ───────
                               │                      ← BindComplete ────────
                               │                      ← NoData ──────────────
                               │                      ← CommandComplete ─────
                               │                      ← ReadyForQuery ───────
                               │                      │                      │
                               │ ← ResultReader       │                      │
                               │ reader.close() → tag │                      │
                               │                      │                      │
                               │ ← ExecResult         │                      │
 result.affected_rows() → 1   │                      │                      │
```

## Testing strategy

| Layer | Test file | What it covers |
|---|---|---|
| Wire protocol | `wire/config_test.mbt` | Connection-string parsing |
| | `wire/raw_conn_test.mbt` | Connect, auth, simple query, extended query, error paths, row iteration |
| Value codec | `value.mbt` (inline tests) | `encode_*` / `decode_*` round-trips, `FromRaw` for basic types |
| Type impls | `types.mbt` (inline tests) | Timestamp parsing, edge cases |
| Connection API | `conn_test.mbt` | `connect`, `query`, `execute`, `query_one`, `Row` access, `Rows` trait, nullable, UTF-8, error handling, async concurrency |
| Transactions | `tx_test.mbt` | `begin_tx`, commit, rollback, isolation, `begin_func`, `TxBeginner` trait |
| Pool | `pool_test.mbt` | Acquire/release, min-idle, max-conns, close, query/execute via pool, pool transactions |
| Integration | `integration_test.mbt` | Full end-to-end: DDL, DML, all types, `query_one`, nullable, UTF-8 text/columns/errors, async interleaving |

Every test that touches a table uses a **unique table name** with `DROP TABLE IF
EXISTS` / `CREATE TABLE` to guarantee isolation regardless of execution order.
