# jaredzhou/moonpg

A MoonBit client for PostgreSQL, based on the `libpq` C library.

## Overview

`moonpg` is a thin, idiomatic MoonBit binding over `libpq`. It provides:

- `Connection` for connecting to a PostgreSQL server with a libpq-style
  connection string.
- `Rows` / `Row` for typed iteration over `SELECT` results — values are
  decoded from text bytes through the `FromValue` trait.
- `ExecResult` for the row counts of `INSERT` / `UPDATE` / `DELETE` / DDL.
- Parameterized queries (`Connection::query` / `Connection::execute` with
  `params=[...]`) via `PQexecParams`, with automatic `NULL` handling for
  nullable columns via `Option[T]`.
- `ToValue` impls for `Int`, `Int64`, `Double`, `Bool`, `String`, `Bytes`,
  and `Option[T : ToValue]`.

## Install

This package targets native builds and links against `libpq`. On Debian / Ubuntu:

```bash
sudo apt install libpq-dev
```

Then in your project:

```bash
moon add jaredzhou/moonpg
```

## Quick start

```moonbit nocheck
let conn = @moonpg.connect("postgres://user:pw@localhost:5432/db")

// Plain SQL — PQexec
let rows = conn.query("SELECT id, name FROM users")
for row in rows.iter() {
  let id : Int = row.get(0)
  let name : String = row.get_by_name("name")
  ignore((id, name))
}
rows.free()

// Parameterized — PQexecParams
let p_id : Int = 42
let p_email : String? = None
conn.execute(
  "UPDATE users SET email = $1 WHERE id = $2",
  params=[p_email, p_id],
) |> ignore

conn.close()
```

## Typed decoding

`Row::get[T : FromValue](col)` and `Row::get_by_name[T : FromValue](name)`
return the cell value decoded to `T`. The basic impls raise on `NULL`:

```moonbit nocheck
///|
let id : Int = row.get(0) // raises on NULL
```

For nullable columns, use `Option[T]`:

```moonbit nocheck
///|
let email : String? = row.get_by_name("email")
```

## Run the integration tests

```bash
MOONPG_CONNINFO="postgres://postgres:111111@localhost:5432/postgres" \
  moon test --target native
```

## License

Apache-2.0