# jaredzhou/moonpg

A pure MoonBit PostgreSQL client — wire protocol from scratch, zero C dependencies.

## Features

- **Query & Fetch** — `query`/`query_one`/`execute` for manual control, `fetch`/`fetch_one` with `FromRow` for typed auto-mapping to structs or tuples.
- **Type-safe codec** — `ToValue` encodes parameters, `FromValue` decodes results; all base types, `Json`, `Timestamp`, `Decimal`, `UUID`, `Option<T>` supported.
- **Connection pool** — bounded pool with acquire/release, min-idle, idle-timeout, health check, background maintenance.
- **Transactions** — `begin_tx` / `commit` / `rollback` + `begin_func` auto-commit/rollback.
- **Async** — multiple connections run concurrently; slow queries never block others.
- **COPY** — streaming bulk insert from iterators.
- **LISTEN / NOTIFY** — async notification support.
- **TLS** — `sslmode` support (disable, require, verify-ca, verify-full) with client certificates.

## Install

```bash
moon add jaredzhou/moonpg
```

## Quickstart

```moonbit nocheck
let conn = @moonpg.connect("postgres://user:pw@localhost:5432/db")

// Execute DDL / DML
conn.execute("CREATE TABLE users (id SERIAL PRIMARY KEY, name TEXT, email TEXT)") |> ignore
conn.execute(
  "INSERT INTO users (name, email) VALUES ($1, $2)",
  params=["alice", "a@b.com"],
) |> ignore

// fetch — typed array of rows (auto-closes)
let names : Array[String] = &QueryExecutor::fetch(conn, "SELECT name FROM users ORDER BY id")
let count : Int = &QueryExecutor::fetch_one(conn, "SELECT COUNT(*) FROM users")

// fetch with tuples
let users : Array[(Int, String)] = &QueryExecutor::fetch(conn, "SELECT id, name FROM users")
let (id, name) = &QueryExecutor::fetch_one(conn, "SELECT id, name FROM users WHERE id = $1", params=[1])

// query — manual iteration (MUST close rows in try-catch)
let rows = conn.query("SELECT id, name FROM users")
try {
  while rows.has_next() {
    let row = rows.get_row()
    let id : Int = row.get(0)
    let name : String = row.get_by_name("name")
  }
  rows.close()
} catch {
  e => { rows.close(); raise e }
}
```

## Query

### fetch / fetch_one

`fetch` and `fetch_one` collect rows into typed results and **auto-close** — no manual `rows.close()` or try-catch needed. They're the recommended way to read data.

```moonbit nocheck
let conn = @moonpg.connect(conninfo)

// Scalar
let count : Int = &QueryExecutor::fetch_one(conn, "SELECT COUNT(*) FROM users")

// Nullable
let email : String? = &QueryExecutor::fetch_one(conn, "SELECT email FROM users WHERE id = $1", params=[1])

// Tuples — no struct needed
let pairs : Array[(Int, String)] = &QueryExecutor::fetch(conn, "SELECT id, name FROM users")
let (id, name, email) : (Int, String, String) = &QueryExecutor::fetch_one(conn,
  "SELECT id, name, email FROM users WHERE id = $1", params=[1],
)

// Custom FromRow struct
impl FromRow for User with fn from_row(r : Row) -> User raise PgError {
  User::{ id: r.get(0), name: r.get(1), email: r.get(2) }
}
let users : Array[User] = &QueryExecutor::fetch(conn, "SELECT id, name, email FROM users")
// Or cast to &QueryExecutor for dot-syntax:
let q : &QueryExecutor = conn
let count : Int = q.fetch_one("SELECT COUNT(*) FROM users")
let names : Array[String] = q.fetch("SELECT name FROM users")
```

### query / query_one

`query` returns a `&Rows` iterator. You **must** call `rows.close()` to drain results and (for pool connections) return the connection. Always use try-catch so `close()` runs even on decode errors.

```moonbit nocheck
// query — iterate rows manually
let rows = conn.query("SELECT id, name FROM users")
try {
  while rows.has_next() {
    let row = rows.get_row()
    let id : Int = row.get(0)
    let name : String = row.get_by_name("name")
    println("\{id}: \{name}")
  }
  rows.close()
} catch {
  e => { rows.close(); raise e }
}

// query_one — single row
let row = conn.query_one("SELECT id FROM users WHERE name = $1", params=["alice"])
let id : Int = row.get(0)
```

### execute

```moonbit nocheck
conn.execute(
  "UPDATE users SET email = $1 WHERE id = $2",
  params=[None, 42],  // Option[T] → SQL NULL
) |> ignore
```

## Pool

```moonbit nocheck
let pool = Pool::new(PoolConfig::new(
  "postgres://user:pw@localhost:5432/db",
  max_conns=10,
  min_idle=2,
))

// Auto-acquire + auto-release — fetch/rows.close() returns conn to pool
let names : Array[String] = &QueryExecutor::fetch(pool, "SELECT name FROM users")
pool.execute("INSERT INTO users (name) VALUES ($1)", params=["bob"]) |> ignore

// Manual query with try-catch
let rows = pool.query("SELECT id FROM users")
try {
  while rows.has_next() { ... }
  rows.close()
} catch {
  e => { rows.close(); raise e }
}

// Explicit acquire
let pc = pool.acquire()
pc.execute("DELETE FROM users WHERE id = $1", params=[1]) |> ignore
pc.release()

// Inspect pool
let stats = pool.stats()
println("active=\{stats.active_connections} idle=\{stats.idle_connections}")

// Health check + background maintenance
let pool2 = Pool::new(PoolConfig::new(
  conninfo,
  max_conns=10,
  min_idle=2,
  max_idle_sec=300,
  max_lifetime_sec=3600,
  health_check=true,
  maintenance_interval_sec=60,
))
pool2.start_maintenance()
```

## Transactions

```moonbit nocheck
let conn = @moonpg.connect(conninfo)

// begin_func — auto-commit on success, auto-rollback on error
let result = begin_func(conn, async fn(tx) {
  tx.execute("INSERT INTO users (name) VALUES ($1)", params=["alice"]) |> ignore
  &QueryExecutor::fetch_one(tx, "SELECT id FROM users WHERE name = $1", params=["alice"])
})

// Manual transaction — try { commit } catch { rollback }
let tx = conn.begin_tx()
try {
  tx.execute("UPDATE users SET name = $1 WHERE id = $2", params=["bob", 1]) |> ignore
  let name : String = &QueryExecutor::fetch_one(tx, "SELECT name FROM users WHERE id = $1", params=[1])
  tx.commit()
} catch {
  e => { tx.rollback(); raise e }
}

// Pooled transaction — connection auto-returns to pool on commit/rollback
let pool = Pool::new(PoolConfig::new(conninfo, max_conns=4))
let tx2 = pool.begin_tx()
try {
  tx2.execute("DELETE FROM users WHERE id = $1", params=[99]) |> ignore
  tx2.commit()
} catch {
  e => { tx2.rollback(); raise e }
}
```

## ToValue / FromValue

```moonbit nocheck
// ToValue — MoonBit → PostgreSQL
// Built-in impls: Int, Int64, Double, Bool, String, Bytes, Json,
//                 Timestamp, Decimal, UUID, Option<T>
let params = [42, 3.14, true, "hello", None] // None → SQL NULL
conn.execute("INSERT INTO t (a, b, c, d, e) VALUES ($1, $2, $3, $4, $5)", params=params)

// FromValue — PostgreSQL → MoonBit
let row = conn.query_one("SELECT a, b, c, d, e FROM t")
let a : Int = row.get(0)            // strict: raises on NULL
let b : String? = row.get(1)        // nullable: NULL → None
let c : Bool = row.get_by_name("c") // by column name
let d : Json = row.get(3)           // jsonb → Json
let e : Timestamp = row.get(4)      // timestamptz → Unix µs

// Custom impl
impl ToValue for MyType with fn to_value(self) -> Value {
  Value::String(self.to_json())
}
impl FromValue for MyType with fn from_value(v : Value) -> MyType raise ValueError {
  match v { Value::String(s) => MyType::from_json(s); _ => raise ... }
}
```

## FromRow

```moonbit nocheck
// Single-column rows: built-in impls for all FromValue types
let count : Int = &QueryExecutor::fetch_one(conn, "SELECT COUNT(*) FROM users")
let name : String? = &QueryExecutor::fetch_one(conn, "SELECT name FROM users WHERE id = $1", params=[1])

// Custom struct
impl FromRow for User with fn from_row(r : Row) -> User raise PgError {
  User::{ id: r.get(0), name: r.get(1), email: r.get(2) }
}
let users : Array[User] = &QueryExecutor::fetch(conn, "SELECT id, name, email FROM users")

// Tuple impls (2–10)
let pairs : Array[(Int, String)] = &QueryExecutor::fetch(conn, "SELECT id, name FROM users")
let (id, name, email) : (Int, String, String) = &QueryExecutor::fetch_one(conn,
  "SELECT id, name, email FROM users WHERE id = $1", params=[1],
)
```

## Connection properties

```moonbit nocheck
let pid = conn.backend_pid()            // server process ID
let ver = conn.param("server_version")  // e.g. Some("16.4")
let tz  = conn.param("TimeZone")        // e.g. Some("UTC")
if conn.is_closed() { ... }
```

## TLS / SSL

```moonbit nocheck
// System CA
@moonpg.connect("postgres://user:pw@host/db?sslmode=require")

// Custom CA
@moonpg.connect("postgres://user:pw@host/db?sslmode=verify-ca&sslrootcert=/etc/ca.pem")

// Client certificate
@moonpg.connect(
  "postgres://user:pw@host/db?sslmode=require&sslcert=/etc/certs/client.pem&sslkey=/etc/certs/client.key",
)
```

Supported sslmodes: `disable`, `allow`, `prefer`, `require`, `verify-ca`, `verify-full`.

## LISTEN / NOTIFY

```moonbit nocheck
@async.with_task_group() <| group => {
  let listener = conn.listen("events", group)

  group.spawn_bg() <| () => {
    let c2 = @moonpg.connect(conninfo)
    c2.notify("events", payload="hello")
  }

  let notif = listener.recv()
  println("\{notif.channel}: \{notif.payload}")
}
```

## COPY protocol

```moonbit nocheck
// Bulk insert from an iterator — one row in memory at a time
conn.copy_in("COPY users (name, age) FROM STDIN", ["alice\t30\n", "bob\t25\n"].iter())

// Streaming COPY writer
let w = conn.begin_copy("users", ["name", "age"])
w.write_row(["alice", 30])
w.write_row(["bob", 25])
let result = w.finish()
```

## Connection timeouts

```moonbit nocheck
// TCP connect timeout (seconds)
@moonpg.connect("postgres://host/db?connect_timeout=5")

// Server-side statement timeout (milliseconds)
@moonpg.connect("postgres://host/db?statement_timeout=30000")
```

## Target session attributes

```moonbit nocheck
@moonpg.connect("postgres://host/db?target_session_attrs=read-write")
```

Values: `any` (default), `read-write`, `read-only`, `primary`, `standby`, `prefer-standby`.

## Architecture

See [arch.md](./arch.md) for a detailed walkthrough of the codebase.

## Run the tests

```bash
# Default connection
moon test --target native

# Custom connection
PGCONN="postgres://user:pass@localhost:5432/mydb" moon test --target native
```

### Auth tests (optional)

| env var         | example connstr                                                 | auth method   |
|-----------------|-----------------------------------------------------------------|---------------|
| `PG_PLAIN_CONN` | `postgres://moonpg_plain:plain_pass@localhost:5432/moonpg_test` | password      |
| `PG_MD5_CONN`   | `postgres://moonpg_md5:md5_pass@localhost:5432/moonpg_test`     | md5           |
| `PG_SCRAM_CONN` | `postgres://moonpg_scram:scram_pass@localhost:5432/moonpg_test` | scram-sha-256 |

## License

Apache-2.0
