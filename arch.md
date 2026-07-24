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
                   │  wire/                           │  ← wire protocol
                   │  raw_conn.mbt  result_reader.mbt  │
                   │  frontend_messages.mbt            │
                   │  backend_messages.mbt             │
                   │  config.mbt  auth_md5 / auth_scram│
                   └──────────────┬───────────────────┘
                   ┌──────────────┴───────────────────┐
                   │  pgtype/                         │  ← codec registry
                   │  Codec trait  TypeMap  &Codec    │
                   │  12 codecs (Bool, Int, Float, …)  │
                   └──────────────┬───────────────────┘
                   ┌──────────────┴───────────────────┐
                   │  value/                          │  ← pure data layer
                   │  Value(9)  Format  ToValue       │
                   │  FromValue  Timestamp            │
                   └──────────────┬───────────────────┘
                   ┌──────────────┴───────────────────┐
                   │  moonbitlang/async                │  ← platform
                   │  @socket.Tcp  @async.all          │
                   └──────────────────────────────────┘
```

Dependency chain: `value/` ← `pgtype/` ← `wire/` ← `root`. No cycles.

## Module walkthrough

### `value/` — Pure data types & conversion traits

Zero internal dependencies. Provides the foundational types:

- `Value` enum (9 variants): `Null`, `Bool`, `Int`, `Int64`, `Float`, `String`,
  `Bytes`, `Timestamp(Int64)`, `Json(Json)`.
- `Format` enum: `Text` | `Binary`.
- `ToValue` trait: single method `to_value(Self) -> Value`.
- `FromValue` trait: single method `from_value(Value) -> Self raise ValueError`.
- Built-in `ToValue` / `FromValue` impls for `Int`, `Int64`, `Double`, `Bool`,
  `String`, `Bytes`, `Json`, `Decimal`, `UUID`, `Option[T]`, and `Timestamp`.
- `Timestamp` struct: Unix-epoch microseconds, with `ToValue`/`FromValue` impls.

No wire encoding knowledge — that lives in `pgtype/`.

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

Key design:
- Each codec is a stateless struct implementing `Codec`.
- `Type.codec` is `&Codec` — a MoonBit trait object stored directly in the struct.
  No enum dispatch needed.
- `encode` returns `Bytes?` — `None` for SQL NULL, `Some(bytes)` for values.
- `decode` accepts `Bytes?` — `None` → `Value::Null`.
- Unknown OIDs fall back to `TextCodec`.
- Value variant compatibility: e.g. `Int8Codec` accepts `Value::Int` (widens),
  `JSONCodec` accepts `Value::String` (passes through).

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

### `conn.mbt` — Connection & query API (public)

- `Connection` — wraps a wire-level `RawConn`.
- `Rows` trait — `has_next()`, `get_row()`, `columns()`, `close()`.
- `QueryExecutor` trait — `query()`, `query_one()`, `execute()`.
  Uses `&@value.ToValue` for parameters.
- `Row` — values as `Array[Bytes?]`, decoded lazily via
  `codec.decode(oid, format, bytes?)` → `FromValue::from_value(val)`.
- `ExecResult` — `affected_rows()`.
- `PgError` — `ConnectionError`, `QueryError`, `NoRows`.

### `pool.mbt` — Connection pool

- `Pool` — idle-queue based. `acquire()` / `release()`.
- `PoolConfig` — `conninfo`, `max_conns`, `min_idle`, `max_idle_sec`,
  `max_lifetime_sec`, `maintenance_interval_sec`.
- `PoolConn`, `PoolRows`, `PoolDbTx`.
- `Pool` implements `QueryExecutor`.

### `tx.mbt` — Transactions

- `Tx` trait — `commit()` / `rollback()`.
- `TxBeginner` trait — `begin_tx()`.
- `DbTx` — concrete transaction with `QueryExecutor`.

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
   `result_formats` are optionally synthesized from `stmt.fields[].format`.

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
| Value traits | `value/value.mbt` (inline tests) | `ToValue`/`FromValue` round-trips, NULL, mismatches, compatibility, all types including Decimal/UUID/Timestamp |
| Codec | `pgtype/` (inline tests) | Each codec's text/binary round-trip, NULL, edge values, variant compatibility |
| Connection API | `conn_test.mbt` | `connect`, `query`, `execute`, `query_one`, `Row` access, `Rows` trait |
| Transactions | `tx_test.mbt` | `begin_tx`, commit, rollback, isolation, `begin_func` |
| Pool | `pool_test.mbt` | Acquire/release, min-idle, max-conns, close, pool transactions |
| Integration | `integration_test.mbt` | End-to-end DDL/DML, all types (incl. jsonb, timestamptz), nullable, binary format, bytea, async interleaving |

281 tests total. Every test that touches a table uses `DROP TABLE IF EXISTS` /
`CREATE TABLE` for isolation.
