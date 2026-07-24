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
- **Typed decoding** — `FromValue` trait for `Int`, `Int64`, `Double`, `Bool`, `String`,
  `Bytes`, `Json`, `Decimal`, `UUID`, `Timestamp`, plus `Option[T]` for nullable columns.
- **Parameterised queries** — `$1`-style placeholders via the extended query protocol;
  `ToValue` trait with impls for all basic types and `Option[T]`.
- **Codec-based encoding** — per-PG-type codecs with OID dispatch; `&Codec` trait objects
  handle text and binary format transparently.  Supports variant compatibility (e.g.
  `String` → JSON, `Int` → `Int64`).
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

### TLS / SSL

```moonbit nocheck
// System CA (default)

///|
let conn = @moonpg.connect("postgres://user:pw@host/db?sslmode=require")

// Custom CA certificate

///|
let conn = @moonpg.connect(
  "postgres://user:pw@host/db?sslmode=verify-ca&sslrootcert=/etc/certs/ca.pem",
)

// Client certificate

///|
let conn = @moonpg.connect(
  "postgres://user:pw@host/db?sslmode=require&sslcert=/etc/certs/client.pem&sslkey=/etc/certs/client.key",
)
```

Supported sslmodes: `disable`, `allow`, `prefer`, `require`, `verify-ca`, `verify-full`.

### Connection timeouts

```moonbit nocheck
// TCP connect timeout (seconds)
@moonpg.connect("postgres://host/db?connect_timeout=5")

// Server-side statement timeout (milliseconds)
@moonpg.connect("postgres://host/db?statement_timeout=30000")
```

### Target session attributes

```moonbit nocheck
// Ensure we're talking to a read-write primary
@moonpg.connect("postgres://host/db?target_session_attrs=read-write")

// Read-only standby is fine
@moonpg.connect("postgres://host/db?target_session_attrs=read-only")
```

Values: `any` (default), `read-write`, `read-only`, `primary`, `standby`, `prefer-standby`.

### Connection properties

```moonbit nocheck
let pid = conn.backend_pid()            // server process ID
let ver = conn.param("server_version")  // e.g. Some("16.4")
let tz  = conn.param("TimeZone")        // e.g. Some("UTC")
if conn.is_closed() { ... }
```

### LISTEN / NOTIFY

```moonbit nocheck
@async.with_task_group() <| group => {
  let listener = conn.listen("events", group)

  // Notify from another connection
  group.spawn_bg() <| () => {
    let c2 = @moonpg.connect(conninfo)
    c2.notify("events", payload="hello")
  }

  // Block until a notification arrives
  let notif = listener.recv()
  println("\{notif.channel}: \{notif.payload}")
}
```

### COPY protocol

```moonbit nocheck
// Bulk insert from an iterator — one row in memory at a time
conn.copy_in("COPY users (name, age) FROM STDIN", ["alice\t30", "bob\t25"].iter())

// Streaming COPY writer
let w = conn.begin_copy("users", ["name", "age"])
w.write_row(["alice", 30])
w.write_row(["bob", 25])
let result = w.finish()
```

### Pool with health check and stats

```moonbit nocheck
let pool = Pool::new(PoolConfig::new(
  "postgres://user:pw@localhost:5432/db",
  max_conns=10,
  min_idle=2,
  max_idle_sec=300,
  max_lifetime_sec=3600,
  health_check=true,           // ping idle conns before checkout
  maintenance_interval_sec=60, // background idle-pool sweeper
))

// Start background maintenance
pool.start_maintenance()

// Inspect pool
let stats = pool.stats()
println("active=\{stats.active_connections} idle=\{stats.idle_connections}")

pool.close()
```

### Transactions

```moonbit nocheck
// Auto-commit / rollback

///|
let result = begin_func(conn, async fn(tx) {
  tx.execute("INSERT INTO users (name) VALUES ($1)", params=["alice"]) |> ignore
  tx.query_one("SELECT id FROM users WHERE name = $1", params=["alice"]).get(0)
}) // exception → rollback; success → commit
```

## Typed decoding

`FromValue` decodes PostgreSQL cells into MoonBit types:

```moonbit nocheck
///|
let id : Int = row.get(0) // raises on NULL

///|
let email : String? = row.get_by_name("email") // NULL → None

///|
let js : Json = row.get(2) // jsonb → Json

///|
let ts : @value.Timestamp = row.get(3) // pg timestamptz → Unix µs
```

## Architecture

See [arch.md](./arch.md) for a detailed walkthrough of the codebase.

## Run the tests

Requires a running PostgreSQL instance.  Set `PGCONN` to point at your database
(defaults to `postgres://postgres:111111@localhost:5432/postgres`):

```bash
# Uses default connection
moon test --target native

# Or with a custom connection
PGCONN="postgres://user:pass@localhost:5432/mydb" moon test --target native
```

### Authentication tests (optional)

Three authentication tests (plain password, MD5, SCRAM-SHA-256) require
separate users.  Set the corresponding environment variable for each; tests are
**skipped** when the variable is missing, so you can run the full suite without
them.

| env var         | example connstr                                                     | auth method   |
|-----------------|---------------------------------------------------------------------|---------------|
| `PG_PLAIN_CONN` | `postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test`     | password      |
| `PG_MD5_CONN`   | `postgres://moonpg_md5:md5_pass@localhost:5432/moonpg_test`         | md5           |
| `PG_SCRAM_CONN` | `postgres://moonpg_scram:scram_pass@localhost:5432/moonpg_test`     | scram-sha-256 |

## License

Apache-2.0
