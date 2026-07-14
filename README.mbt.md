# jaredzhou/moonpg

A pure MoonBit PostgreSQL client — wire protocol from scratch, zero C dependencies.

## Overview

`moonpg` speaks the PostgreSQL wire protocol (v3) directly over TCP.  It provides:

- **Connection** — connect, authenticate (cleartext / MD5 / SCRAM-SHA-256), query, close.
- **Pool** — bounded connection pool with acquire / release, min-idle, and idle-timeout
  expiry.
- **Transactions** — `begin_tx` / `commit` / `rollback` on bare connections and pooled
  connections, plus `begin_func` (auto-commit/rollback).
- **Rows trait** — polymorphic row iteration (`ConnRows`, `PoolRows`); pull-based with
  `has_next()` / `get_row()`.
- **Typed decoding** — `FromRaw` trait for `Int`, `Int64`, `Double`, `Bool`, `String`,
  `Bytes`, `Json`, `Decimal`, `UUID`, `Timestamp`, plus `Option[T]` for nullable columns.
- **Parameterised queries** — `$1`-style placeholders via the extended query protocol;
  `ToValue` trait with impls for all basic types and `Option[T]`.
- **Async concurrency** — multiple connections can run queries concurrently; a slow
  query on one connection never blocks others.

## Install

This package targets **native** builds and has **zero C dependencies** — the wire protocol
is implemented in pure MoonBit.

```bash
moon add jaredzhou/moonpg
```

## Quick start

```moonbit nocheck
let conn = @moonpg.connect("postgres://user:pw@localhost:5432/db")

// Simple query
let rows = conn.query("SELECT id, name FROM users")
while rows.has_next() {
  let row = rows.get_row()
  let id : Int = row.get(0)
  let name : String = row.get_by_name("name")
  println("\{id}: \{name}")
}
rows.close()

// Parameterised — extended query protocol
conn.execute(
  "UPDATE users SET email = $1 WHERE id = $2",
  params=[None, 42],  // Option[T] encodes NULL
) |> ignore

conn.close()
```

### Connection pool

```moonbit nocheck
let pool = Pool::new(PoolConfig::new(
  "postgres://user:pw@localhost:5432/db",
  max_conns=10,
  min_idle=2,
))

// Implicit acquire — rows.close() returns conn to pool
let rows = pool.query("SELECT 1")
while rows.has_next() {
  let row = rows.get_row()
  // ...
}
rows.close()

let row = pool.query_one("SELECT 42")
pool.execute("INSERT INTO t (x) VALUES ($1)", params=[1]) |> ignore

// Explicit acquire — caller controls release
let pc = pool.acquire()
let r = pc.execute("INSERT INTO t (x) VALUES ($1)", params=[99])
r.close()
pc.release()
```

### Transactions

```moonbit nocheck
// Auto-commit / rollback
let result = begin_func(conn, async fn(tx) {
  tx.execute("INSERT INTO users (name) VALUES ($1)", params=["alice"]) |> ignore
  tx.query_one("SELECT id FROM users WHERE name = $1", params=["alice"])
    .get(0)
})  // exception → rollback; success → commit
```

## Typed decoding

`FromRaw` decodes PostgreSQL cells into MoonBit types:

```moonbit nocheck
let id : Int      = row.get(0)            // raises on NULL
let email : String? = row.get_by_name("email")  // NULL → None
let ts : Timestamp  = row.get(2)          // pg timestamp → Unix µs
```

## Architecture

See [arch.md](./arch.md) for a detailed walkthrough of the codebase.

## Run the tests

Requires a running PostgreSQL instance with three test users:

| user          | password    | auth method   |
|---------------|-------------|---------------|
| moonpg_plain  | plain_pass  | password      |
| moonpg_md5    | md5_pass    | md5           |
| moonpg_scram  | scram_pass  | scram-sha-256 |

```bash
# Use env var or defaults (see conn_test.mbt)
MOONPG_CONNINFO="postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test" \
  moon test --target native
```

## License

Apache-2.0
