# moonpg architecture

moonpg is a pure-MoonBit PostgreSQL client that speaks the [PostgreSQL wire
protocol (v3)](https://www.postgresql.org/docs/current/protocol.html) directly
over TCP.  There are zero C dependencies — no libpq, no native stubs.

## Layer diagram

```
                   ┌──────────────────────────────────────┐
                   │  moonpg.mbt   conn.mbt   pool.mbt   │  ← public API
                   │  tx.mbt   from_row.mbt   values.mbt  │
                   │  (traits: QueryExecutor Rows FromRow │
                   │   Tx TxBeginner ToValue FromValue)   │
                   └──────────────┬───────────────────────┘
                   ┌──────────────┴───────────────────────┐
                   │  wire/                               │  ← wire protocol
                   │  raw_conn.mbt  result_reader.mbt      │
                   │  frontend_messages.mbt                │
                   │  backend_messages.mbt                 │
                   │  config.mbt  auth_md5 / auth_scram    │
                   └──────────────┬───────────────────────┘
                   ┌──────────────┴───────────────────────┐
                   │  pgtype/                             │  ← codec registry
                   │  Codec trait  TypeMap  &Codec        │
                   │  12 codecs (Bool, Int, Float, …)      │
                   └──────────────┬───────────────────────┘
                   ┌──────────────┴───────────────────────┐
                   │  value/                              │  ← pure data
                   │  Value(9 variants)  Format            │
                   └──────────────┬───────────────────────┘
                   ┌──────────────┴───────────────────────┐
                   │  moonbitlang/async                    │  ← platform
                   │  @socket.Tcp  @async.all              │
                   └──────────────────────────────────────┘
```

Dependency chain: `value/` ← `pgtype/` ← `wire/` ← `root`. No cycles.

## File layout

### `moonpg.mbt` — Public traits & core types

Central API surface. Re-exports `Value` and `Format` from `value/`.

| Section | Contents |
|---|---|
| Error types | `PgError` (ConnectionError, QueryError, NoRows), `ValueError` |
| Value traits | `ToValue`, `FromValue` |
| Row traits | `Rows` trait, `Row` struct + `get()` / `get_by_name()`, `ExecResult` |
| Query executor | `QueryExecutor` trait (query, query_one, execute, close) + `fetch` / `fetch_one` extension methods on `&QueryExecutor` |
| Row mapping | `FromRow` trait |
| Transactions | `Tx` trait, `TxBeginner` trait, `TxOptions`, `IsolationLevel`, `DbTx` |
| Transaction helpers | `begin_func` |

### `from_row.mbt` — FromRow implementations

- `FromRow` impls for all base types: `Int`, `Int64`, `Double`, `Bool`, `String`, `Bytes`, `Json`, `Timestamp`, `Decimal`, `UUID`, `Option<T>`.
- `FromRow` impls for 2-tuple through 10-tuple. Each element mapped via `Row::get(i)` → `FromValue`.

### `values.mbt` — ToValue / FromValue implementations

- `Timestamp` struct (Unix-epoch microseconds).
- `ToValue` / `FromValue` impls for all base types: `Int`, `Int64`, `Double`, `Bool`, `String`, `Bytes`, `Json`, `Decimal`, `UUID`, `Option<T>`, `Timestamp`.
- Inline tests for every type's round-trip.

### `conn.mbt` — Connection & query API

- `Connection` — wraps a wire-level `RawConn`.
- `ConnStatus` enum (OK, Bad).
- `ConnRows` — `Rows` impl backed by `ResultReader`.
- `Listener` — async notification receiver.
- `CopyWriter` — streaming COPY FROM STDIN.
- `exec_params` — prepare → encode → execute flow for parameterised queries.
- `Connection` implements `QueryExecutor`, `TxBeginner`.

### `pool.mbt` — Connection pool

- `Pool` — idle-queue based. `acquire()` / `release()`.
- `PoolConfig` — `conninfo`, `max_conns`, `min_idle`, `max_idle_sec`, `max_lifetime_sec`, `maintenance_interval_sec`.
- `PoolConn`, `PoolRows`, `PoolDbTx`.
- `Pool`, `PoolConn`, `PoolDbTx` all implement `QueryExecutor`.
- `Pool` and `PoolConn` implement `TxBeginner`.

### `tx.mbt` — Transaction implementations

- `build_begin_sql` — build `BEGIN ...` SQL from `TxOptions`.
- `TxBeginner` impls for `Connection`, `Pool`, `PoolConn`.
- `QueryExecutor` and `Tx` impls for `DbTx`.

### `value/` — Pure data types

Minimal sub-package. No internal dependencies.

- `Value` enum (9 variants): `Null`, `Bool(Bool)`, `Int(Int)`, `Int64(Int64)`, `Float(Double)`, `String(String)`, `Bytes(Bytes)`, `Timestamp(Int64)`, `Json(Json)`.
- `Format` enum: `Text` | `Binary`.

Traits (`ToValue`, `FromValue`) and their impls live in the root package (`moonpg.mbt` + `values.mbt`).

### `pgtype/` — Codec registry & type map

Depends on `value/`. Contains the codec system:

| File | Purpose |
|---|---|
| `codec.mbt` | `Codec` trait: `prefer_format`, `encode(Value) → Bytes?`, `decode(Bytes?) → Value`. `CodecError` suberror. |
| `types.mbt` | `Type { name, oid, &Codec }`, `TypeMap` with `codec_for(oid) → &Codec`, ~90 OID constants, `default_map`. |
| `text_codec.mbt` | `TextCodec` — UTF-8 encode/decode for text/varchar/bpchar/name/unknown. |
| `numeric_codec.mbt` | `BoolCodec`, `Int2Codec`, `Int4Codec`, `Int8Codec`, `Float4Codec`, `Float8Codec`. |
| `string_binary_json_codec.mbt` | `ByteaCodec`, `JSONCodec`, `JSONBCodec`, `TimestampCodec`, `TimestamptzCodec`. |
| `encode_decode.mbt` | Low-level binary helpers (`encode_int4`, `decode_int8`, etc.). |

### `wire/` — PostgreSQL wire protocol

| File | Purpose |
|---|---|
| `raw_conn.mbt` | TCP connect, SSL negotiation, startup, authentication, `send`/`receive` framing, `simple_query`, `prepare`, `bind`, `describe_statement`, `describe_portal`, `execute`, `execute_statement`, `execute_prepared`, cancel request. |
| `result_reader.mbt` | Pull-based result-set reader. `has_next()` + `data_row()` streaming, `read()` eager collect. |
| `config.mbt` | Connection-string parser (URI + key/value). |
| `frontend_messages.mbt` | All client→server messages. |
| `backend_messages.mbt` | All server→client messages, `FieldDescription`, `StatementDescription`. |
| `auth_md5.mbt` | MD5 password authentication. |
| `auth_scram.mbt` | SCRAM-SHA-256 authentication. |
| `error.mbt` | `WireError` suberror (`PgServer`, `Connect`, `Auth`, `Parse`, `IO`, `InvalidMessage`). |
| `types.mbt` | `CommandTag`, `TransactionStatus`. |

## Two query protocols

### Simple query

`simple_query()` sends a single `Query` message. Used when no parameters.

### Extended query

Parameterised queries use a two-phase flow in `exec_params()`:

1. `prepare("", sql, [])` — Parse + Describe(S) → `StatementDescription` with
   server-inferred `param_oids` and result `fields`.
2. Encode each parameter: `codec.encode(param_oids[i], codec.prefer_format(), val)`.
3. Update `fields[].format` from `codec.prefer_format()`.
4. `execute_statement(stmt, params, param_formats)` — Bind + Execute + Sync.

```
Parse → Describe(S) → Sync          ← prepare()
↓
codec.encode per param_oid
↓
Bind → Execute → Sync               ← execute_statement()
↓
ResultReader (DataRow → CommandComplete → ReadyForQuery)
```

## Encoding / decoding flow

```
Encode:  UserType ──ToValue──▶ Value ──codec.encode(oid, fmt, val)──▶ Bytes?
         (param_oids from Describe(S))    (None = SQL NULL)

Decode:  Bytes? ──codec.decode(oid, fmt, bytes?)──▶ Value ──FromValue──▶ UserType
         (oid + format from FieldDescription)
```

## Async model

Single-threaded cooperative runtime (`moonbitlang/async`). Multiple connections
run concurrently on independent TCP sockets. No threads, no locks — `@aqueue.Queue`
and `Ref[Int]` for shared state.

## Testing strategy

| Layer | Test file | What it covers |
|---|---|---|
| Wire protocol | `wire/config_test.mbt` | Connection-string parsing |
| | `wire/raw_conn_test.mbt` | Connect, auth, simple query, prepare, bind, execute, execute_statement, execute_prepared, error paths |
| Codec | `pgtype/` (inline tests) | Each codec's text/binary round-trip, NULL, edge values, variant compatibility |
| Value traits | `values.mbt` (inline tests) | `ToValue`/`FromValue` round-trips, NULL, mismatches, all types including Decimal/UUID/Timestamp |
| Core API | `moonpg_test.mbt` | `connect`, `execute`, `query`, `query_one`, `Row.get`/`get_by_name`, all basic types, jsonb, timestamptz, nullable, UTF-8, query_one error paths |
| Connection | `conn_test.mbt` | `connect`, `query`, `execute`, `query_one`, `Row` access, `Rows` trait, `server_version`, COPY, LISTEN/NOTIFY, deallocate, binary result format, async interleaving |
| FromRow / fetch | `from_row_test.mbt` | `FromRow` round-trips (base types, custom struct, nullable, tuples 2–10), `fetch`/`fetch_one` on Connection/Pool/PoolConn/PoolDbTx, error paths, pool release-on-error |
| Transactions | `tx_test.mbt` | `begin_tx`, commit, rollback, isolation, `begin_func` |
| Pool | `pool_test.mbt` | Acquire/release, min-idle, max-conns, close, pool transactions, stats, maintenance |

314 tests total. Every test that touches a table uses `DROP TABLE IF EXISTS` /
`CREATE TABLE` for isolation.
