///|
/// PostgreSQL connection configuration.
///
/// Two connection-string formats are accepted, mirroring libpq's `fe-connect.c`:
///
/// **URI** (parsed via `@url.parse`):
/// ```
/// postgresql://[user[:password]@][host][:port][/dbname][?param=value&...]
/// ```
///
/// **Keyword/Value**:
/// ```
/// host=localhost port=5432 user=alice dbname=mydb password=secret
/// ```
/// Values may be single-quoted (`'has spaces'`) and use backslash escaping.
pub(all) struct Config {
  host : String
  hostaddr : String?
  port : Int
  user : String
  database : String?
  password : String?
  sslmode : String
  application_name : String?
  trace : Bool
}

///|
/// The default PostgreSQL TCP port.
pub const DEFAULT_PORT : Int = 5432

///|
/// Create a `Config` with explicit parameter values.
pub fn Config::new(
  user : String,
  host? : String = "localhost",
  hostaddr? : String? = None,
  port? : Int = DEFAULT_PORT,
  database? : String? = None,
  password? : String? = None,
  sslmode? : String = "disable",
  application_name? : String? = None,
  trace? : Bool = false,
) -> Config {
  {
    host,
    hostaddr,
    port,
    user,
    database,
    password,
    sslmode,
    application_name,
    trace,
  }
}

///|
/// Parse a PostgreSQL connection string.
///
/// Auto-detects URI (`postgresql://` / `postgres://`) vs keyword/value format.
pub fn Config::from_connstr(s : String) -> Config {
  if s.has_prefix("postgresql://") || s.has_prefix("postgres://") {
    parse_uri(s)
  } else {
    parse_kv(s)
  }
}

// ---------------------------------------------------------------------------
// URI parsing — delegates to @url.parse
// ---------------------------------------------------------------------------

///|
/// Parse a URI connection string via `@url.parse`.
fn parse_uri(uri_str : String) -> Config {
  let url = @url.parse(uri_str) catch {
    _ => abort("invalid PostgreSQL connection URI: \{uri_str}")
  }

  // user : password
  let (user, password) = match url.user_info {
    Some(info) => (info.username, info.password)
    None => ("", None)
  }

  // host : port  (url.host is the full "host:port" string)
  let (host, port) = match url.host {
    Some(h) => split_hostport(h)
    None => ("localhost", DEFAULT_PORT)
  }

  // database name from path (strip leading /)
  let database : String? = match url.path {
    Some(p) => {
      let trimmed = if p.has_prefix("/") { p[1:].to_owned() } else { p }
      if trimmed.length() > 0 {
        Some(trimmed)
      } else {
        None
      }
    }
    None => None
  }

  // Build from URI components
  let mut config = Config::new(user, host~, port~, database~, password~)

  // Apply query-string overrides (sslmode, application_name, etc.)
  match url.query {
    Some(q) =>
      for pair in q.split("&") {
        match pair.find("=") {
          Some(eq) => {
            let key = pair[0:eq].to_owned()
            let val = pair[eq + 1:].to_owned()
            config = with_param(config, key, val)
          }
          None => ()
        }
      }
    None => ()
  }

  config
}

///|
/// Split `host:port` into `(host, port)`. Handles IPv6 `[::1]:5432`.
fn split_hostport(hostport : String) -> (String, Int) {
  // IPv6: [address]:port
  if hostport.has_prefix("[") {
    match hostport.find("]") {
      Some(close) => {
        let host = hostport[0:close + 1].to_owned()
        let after = hostport[close + 1:]
        let port = if after.has_prefix(":") {
          parse_port(after[1:].to_owned())
        } else {
          DEFAULT_PORT
        }
        return (host, port)
      }
      None => return (hostport, DEFAULT_PORT)
    }
  }
  // Plain host:port
  match hostport.rev_find(":") {
    Some(i) => {
      let h = hostport[0:i].to_owned()
      let p = parse_port(hostport[i + 1:].to_owned())
      (h, p)
    }
    None => (hostport, DEFAULT_PORT)
  }
}

// ---------------------------------------------------------------------------
// Keyword/Value parsing
// ---------------------------------------------------------------------------

///|
/// Parse a keyword/value connection string.
///
/// Format: `key=value [key=value ...]`
///
/// Values may be **bare**, **single-quoted** (`'...'`), or use **backslash
/// escaping**.  Inside single quotes `\'` embeds a literal single quote.
fn parse_kv(s : String) -> Config {
  let mut config = Config::new("")
  for s0 = s.to_string_view() {
    match s0 {
      [' ' | '\t' | '\n' | '\r', .. rest] => continue rest
      [] => break
      _ => {
        let (key, after_eq) = scan_keyword(s0)
        let (value, rest) = scan_value(after_eq)
        config = with_param(config, key, value)
        continue rest
      }
    }
  }
  // Sensible defaults for required fields.
  if config.user == "" {
    config = { ..config, user: "postgres" }
  }
  if config.host == "" {
    config = { ..config, host: "localhost" }
  }
  config
}

///|
/// Scan a keyword until `=`.  Handles optional whitespace before `=`.
///
/// Returns `(keyword, rest_past_=)`.
fn scan_keyword(s : StringView) -> (String, StringView) {
  guard s.find("=") is Some(index) else {
    abort("invalid connection string: expected '=' after '\{s}'")
  }
  // Skip optional whitespace between keyword and `=`.
  let key = s[0:index].trim().to_owned()

  (key, s[index + 1:])
}

///|
/// Dispatch to the appropriate value scanner.
fn scan_value(s : StringView) -> (String, StringView) {
  match s {
    ['\'', ..] => scan_quoted(s)
    _ => scan_bare(s)
  }
}

///|
/// Scan a single-quoted value.  `s` starts with the opening `'`.
///
/// Backslash escapes the next character (`\'` → `'`, `\\` → `\`).
fn scan_quoted(s : StringView) -> (String, StringView) {
  let buf = StringBuilder::new()
  for rest = s[1:] {
    match rest {
      ['\'', .. rest] => return (buf.to_string(), rest)
      [] => abort("unterminated quoted value")
      ['\\', c, .. rest] => {
        buf.write_char(c)
        continue rest
      }
      [c, .. rest] => {
        buf.write_char(c)
        continue rest
      }
    }
  }
}

///|
/// Scan a bare (unquoted) value until whitespace or end.
///
/// Backslash escapes the next character.
fn scan_bare(s : StringView) -> (String, StringView) {
  let buf = StringBuilder::new()
  for rest = s {
    match rest {
      [' ' | '\t' | '\n' | '\r', .. rest] => return (buf.to_string(), rest)
      [] => return (buf.to_string(), rest)
      ['\\', c, .. r] => {
        buf.write_char(c)
        continue r
      }
      [c, .. r] => {
        buf.write_char(c)
        continue r
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Parameter application
// ---------------------------------------------------------------------------

///|
/// Apply a `(key, value)` pair, returning an updated `Config`.
///
/// Keywords are matched case-insensitively (as in libpq). Unknown keywords
/// are silently ignored.
fn with_param(config : Config, key : String, value : String) -> Config {
  match key.to_lower() {
    "host" => { ..config, host: value }
    "hostaddr" => { ..config, hostaddr: Some(value) }
    "port" => { ..config, port: parse_port(value) }
    "user" | "username" => { ..config, user: value }
    "dbname" | "database" => { ..config, database: Some(value) }
    "password" => { ..config, password: Some(value) }
    "sslmode" => { ..config, sslmode: value }
    "application_name" => { ..config, application_name: Some(value) }
    _ => config
  }
}

///|
/// Parse a port string, falling back to `DEFAULT_PORT`.
fn parse_port(s : String) -> Int {
  @string.parse_int(s) catch {
    _ => DEFAULT_PORT
  }
}
