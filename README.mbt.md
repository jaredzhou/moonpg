# jaredzhou/moonpg

A pure MoonBit PostgreSQL client — wire protocol from scratch, zero C dependencies.
Feature-complete with a simple, ergonomic API.

## Features

- **Query & Fetch** — `query`/`query_one`/`execute` for manual control, `fetch`/`fetch_one` with `FromRow` for typed auto-mapping to structs or tuples.
- **Type-safe codec** — `ToValue` encodes parameters, `FromValue` decodes results; all base types, `Json`, `Timestamp`, `Decimal`, `UUID`, `Option<T>` supported.
- **Connection pool** — bounded pool with acquire/release, a `max_conns` ceiling and a `min_conn` warm floor, a 2s checkout ping, a non-blocking `try_acquire`, idle/lifetime timeouts and a maintenance loop.
- **Transactions** — `begin_tx` / `commit` / `rollback` + `begin_func` auto-commit/rollback.
- **COPY** — streaming bulk insert from iterators.
- **LISTEN / NOTIFY** — async notification support.
- **TLS** — `sslmode` support (disable, require, verify-ca, verify-full) with client certificates.
- **Timeouts** — `read_timeout` bounds every read, so a dead or black-holed server fails fast instead of hanging on TCP retransmission. It is off by default: set it in the connection string.

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
let names : Array[String] = conn.fetch("SELECT name FROM users ORDER BY id")
let count : Int = conn.fetch_one("SELECT COUNT(*) FROM users")

// fetch with tuples
let users : Array[(Int, String)] = conn.fetch("SELECT id, name FROM users")
let (id, name) = conn.fetch_one("SELECT id, name FROM users WHERE id = $1", params=[1])

// query — manual iteration (defer rows.close())
let rows = conn.query("SELECT id, name FROM users")
defer rows.close()
while rows.has_next() {
  let row = rows.get_row()
  let id : Int = row.get(0)
  let name : String = row.get_by_name("name")
}
```

## Query

### fetch / fetch_one

`fetch` and `fetch_one` collect rows into typed results and **auto-close** — no manual `rows.close()` or `defer` needed. They're the recommended way to read data.

They're declared in the `Fetching` trait — a non-object-safe companion to
`QueryExecutor`, since `fetch` is generic in `T` — with a single shared
implementation, and are available directly on `Connection`, `Pool`, `PoolConn`,
`DbTx`, `PoolDbTx`, and `&Tx` (the type returned by `begin_tx`). The explicit
`&QueryExecutor::fetch(x, ...)` form keeps working too.

```moonbit nocheck
let conn = @moonpg.connect(conninfo)

// Scalar
let count : Int = conn.fetch_one("SELECT COUNT(*) FROM users")

// Nullable
let email : String? = conn.fetch_one("SELECT email FROM users WHERE id = $1", params=[1])

// Tuples — no struct needed
let pairs : Array[(Int, String)] = conn.fetch("SELECT id, name FROM users")
let (id, name, email) : (Int, String, String) = conn.fetch_one(
  "SELECT id, name, email FROM users WHERE id = $1", params=[1],
)

// Custom FromRow struct
impl FromRow for User with fn from_row(r : Row) -> User raise PgError {
  User::{ id: r.get(0), name: r.get(1), email: r.get(2) }
}
let users : Array[User] = conn.fetch("SELECT id, name, email FROM users")
```

### query / query_one

`query` returns a `&Rows` iterator. Always `defer rows.close()` to drain results and (for pool connections) return the connection — this also runs `close()` on decode errors.

```moonbit nocheck
// query — iterate rows manually
let rows = conn.query("SELECT id, name FROM users")
defer rows.close()
while rows.has_next() {
  let row = rows.get_row()
  let id : Int = row.get(0)
  let name : String = row.get_by_name("name")
  println("\{id}: \{name}")
}

// query_one — single row
let row = conn.query_one("SELECT id FROM users WHERE name = $1", params=["alice"])
let id : Int = row.get(0)
```

### execute

```moonbit nocheck
conn.execute(
  "UPDATE users SET email = $1 WHERE id = $2",
  params=[null, 42],  // null → SQL NULL
) |> ignore
```

## Pool

```moonbit nocheck
let pool = Pool::new(PoolConfig::new(
  "postgres://user:pw@localhost:5432/db",
  max_conns=10,
  min_conn=2,
))

// Auto-acquire + auto-release — fetch/rows.close() returns conn to pool
let names : Array[String] = pool.fetch("SELECT name FROM users")
pool.execute("INSERT INTO users (name) VALUES ($1)", params=["bob"]) |> ignore

// Manual query with defer
let rows = pool.query("SELECT id FROM users")
defer rows.close()
while rows.has_next() { ... }

// Explicit acquire
let pc = pool.acquire()
pc.execute("DELETE FROM users WHERE id = $1", params=[1]) |> ignore
pc.release()

// Non-blocking alternative: None instead of waiting for a connection, and a
// PoolConn carries the same query/fetch/execute the pool does. Where this
// returns, the caller can shed the load, serve a cache, or retry later.
guard pool.try_acquire() is Some(conn) else { return }
defer conn.release()
let names : Array[String] = conn.fetch("SELECT name FROM users")

// Inspect pool
let stats = pool.stats()
println("active=\{stats.active_connections} idle=\{stats.idle_connections}")

// Timeouts. What can go stale, and what acquire() does about each:
//
//   1. Too old or too long idle — max_lifetime_sec (a hard age cap, never handed
//      out, never parked, so the server side can rotate) or max_idle_sec while
//      dropping the connection would still leave min_conn. Both are visible from
//      the timestamps, so acquire() drops the connection as it takes it off the
//      idle queue and looks at the next one — another parked connection if there
//      is one, and only otherwise a fresh connect. The request does not fail; it
//      pays a connect only when there was nothing left to reuse.
//   2. Dropped by the server while parked — nothing local can see this, so a
//      connection that has been parked longer than 2s is pinged before it is
//      handed out. If the ping fails, the connection is discarded and the acquire
//      retries on another one.
//   3. Parked less than 2s — handed out as is: a ping would cost more than the
//      risk it covers.
//
// min_conn counts connections, not idle ones, and is pre-warmed at Pool::new.
let pool2 = Pool::new(PoolConfig::new(
  conninfo,
  max_conns=10,
  min_conn=2,
  max_idle_sec=300,
  max_lifetime_sec=3600,
))

// Maintenance is opt-in, and it takes the group: the loop runs the same checks in
// the background instead of at checkout — it pings the parked connections every
// interval_sec (30 by default), replaces the dead ones, rotates the ones past
// max_lifetime_sec and closes the idle surplus past max_idle_sec rather than
// keeping (and pinging) it forever — all before anyone is handed one, so the
// acquire that follows pays for none of it. interval_sec=0 disables the loop;
// pool.maintain() runs one round by hand. The loop is a child of your group, so
// it lives as long as that scope does and stops on close().
@async.with_task_group() <| group => {
  let pool3 = Pool::new(PoolConfig::new(conninfo, max_conns=10, min_conn=2))
  pool3.start_maintenance(group~, interval_sec=30)
  // ... use pool3 here ...
}
```

## Transactions

```moonbit nocheck
let conn = @moonpg.connect(conninfo)

// begin_func — auto-commit on success, auto-rollback on error
let result = begin_func(conn, async fn(tx) {
  tx.execute("INSERT INTO users (name) VALUES ($1)", params=["alice"]) |> ignore
  tx.fetch_one("SELECT id FROM users WHERE name = $1", params=["alice"])
})

// Manual transaction — try { commit } catch { rollback }
let tx = conn.begin_tx()
try {
  tx.execute("UPDATE users SET name = $1 WHERE id = $2", params=["bob", 1]) |> ignore
  let name : String = tx.fetch_one("SELECT name FROM users WHERE id = $1", params=[1])
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
//                 Timestamp, Decimal, UUID, Option<T>, Array<T>
let params = [42, 3.14, true, "hello", null] // null → SQL NULL
conn.execute("INSERT INTO t (a, b, c, d, e) VALUES ($1, $2, $3, $4, $5)", params=params)

// FromValue — PostgreSQL → MoonBit
let row = conn.query_one("SELECT a, b, c, d, e FROM t")
let a : Int = row.get(0)            // strict: raises on NULL
let b : String? = row.get(1)        // nullable: NULL → None
let c : Bool = row.get_by_name("c") // by column name
let d : Json = row.get(3)           // jsonb → Json
let e : Timestamp = row.get(4)      // timestamptz → Unix µs

// Arrays — PostgreSQL array columns
conn.execute(
  "INSERT INTO items (tags) VALUES ($1)",
  params=[["red", "green", "blue"]],
) |> ignore
let row2 = conn.query_one("SELECT tags FROM items")
let tags : Array[String] = row2.get(0)       // strict: no NULL elements
let tags2 : Array[String?] = row2.get(0)     // nullable: NULL elements → None

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
let count : Int = conn.fetch_one("SELECT COUNT(*) FROM users")
let name : String? = conn.fetch_one("SELECT name FROM users WHERE id = $1", params=[1])

// Custom struct
impl FromRow for User with fn from_row(r : Row) -> User raise PgError {
  User::{ id: r.get(0), name: r.get(1), email: r.get(2) }
}
let users : Array[User] = conn.fetch("SELECT id, name, email FROM users")

// Tuple impls (2–10)
let pairs : Array[(Int, String)] = conn.fetch("SELECT id, name FROM users")
let (id, name, email) : (Int, String, String) = conn.fetch_one(
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

## Connection string

`@moonpg.connect` takes a libpq-style URI, or `key=value` pairs. Every knob lives
there:

| Parameter | Meaning | Default |
| --- | --- | --- |
| `host` / `hostaddr`, `port` | Where to connect. | `localhost`, `5432` |
| `user` / `username`, `password`, `dbname` / `database` | Who and what to log in as. | `user` is required |
| `sslmode` | `disable`, `allow`, `prefer`, `require`, `verify-ca`, `verify-full`. | `disable` |
| `sslrootcert` | CA bundle used by `verify-ca` / `verify-full`. | system CA |
| `sslcert`, `sslkey` | Client certificate and its key. | none |
| `application_name` | Shows up in `pg_stat_activity`. | none |
| `connect_timeout` | Seconds to wait for the TCP connection. | `0`, no timeout |
| `statement_timeout` | Milliseconds before the server cancels a query. | `0`, server default |
| `read_timeout` | Seconds a single read may wait for the server. | `0`, no timeout |
| `target_session_attrs` | `any`, `read-write`, `read-only`, `primary`, `standby`, `prefer-standby`. | `any` |

Keywords are case-insensitive and unknown ones are ignored, as in libpq.

```moonbit nocheck
// TLS: system CA, a custom CA, or a client certificate
@moonpg.connect("postgres://user:pw@host/db?sslmode=require")
@moonpg.connect("postgres://user:pw@host/db?sslmode=verify-ca&sslrootcert=/etc/ca.pem")
@moonpg.connect(
  "postgres://user:pw@host/db?sslmode=require&sslcert=/etc/certs/client.pem&sslkey=/etc/certs/client.key",
)

// Timeouts: TCP connect, server-side statement, client-side read
@moonpg.connect("postgres://host/db?connect_timeout=5&statement_timeout=30000&read_timeout=5")

// Route the connection by what the server is
@moonpg.connect("postgres://host/db?target_session_attrs=read-write")
```

`read_timeout` is the one to think about: it is off by default, and without it a
connection whose server goes silent without closing the socket waits for TCP to
give up (~15 minutes). It bounds every read, so a black-holed server fails fast
instead.

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

## HTTP server + pool, with pony

The server and the pool's maintenance loop are both long-lived, and this runtime
has no detached tasks, so one task group must own both: start the loop with
`pool.start_maintenance(group~)` and let `pony.start` be the group body.

```moonbit nocheck
///|
async fn main {
  @async.with_task_group() <| group => {
    let pool = Pool::new(
      PoolConfig::new(
        "postgres://postgres:pw@localhost:5432/app",
        max_conns=10,
        min_conn=2,
        max_idle_sec=300,
        max_lifetime_sec=3600,
      ),
    )
    defer pool.close()
    // The pool maintains itself from here on.
    pool.start_maintenance(group~, interval_sec=30)

    let r = Router::Router()
    // Handlers share the pool simply by closing over it.
    r.add(HttpMethod::Get, "/users/{id}", ctx => {
      let id : Int32 = ctx.param("id")
      let users : Array[(Int32, String)] = pool.fetch(
        "SELECT id, name FROM users WHERE id = $1",
        params=[id],
      )
      ctx.reply_ok(users)
    })

    // Blocks — the body never returns, which is what keeps the loop alive too.
    pony.start("0.0.0.0:3000", r)
  }
}
```

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
