///|
#external
type Connection

///|
#external
type Result

///|
#borrow(conninfo)
pub extern "C" fn moonpg_connect(conninfo : Bytes) -> Connection = "moonpg_connect"

///|
#borrow(conn, sql)
pub extern "C" fn moonpg_query(conn : Connection, sql : Bytes) -> Result = "moonpg_query"

///|
#owned(conn)
pub extern "C" fn moonpg_close(conn : Connection) -> Unit = "moonpg_close"

///|
#borrow(conn)
pub extern "C" fn moonpg_error_message_bytes(conn : Connection) -> Bytes = "moonpg_error_message_bytes"

///|
#borrow(result)
pub extern "C" fn moonpg_ntuples(result : Result) -> Int = "moonpg_ntuples"

///|
#borrow(result)
pub extern "C" fn moonpg_nfields(result : Result) -> Int = "moonpg_nfields"

///|
/// Returns the raw bytes of the cell. Caller should check
/// `moonpg_getisnull` first; an empty `Bytes` is returned for a NULL cell.
#borrow(result)
pub extern "C" fn moonpg_getvalue_bytes(
  result : Result,
  row : Int,
  col : Int,
) -> Bytes = "moonpg_getvalue_bytes"


///|
#borrow(result)
pub extern "C" fn moonpg_fname_bytes(result : Result, col : Int) -> Bytes = "moonpg_fname_bytes"

///|
#borrow(result)
pub extern "C" fn moonpg_getisnull(
  result : Result,
  row : Int,
  col : Int,
) -> Int = "moonpg_getisnull"

///|
/// Returns the format of column `col`: 0 = text, 1 = binary.
#borrow(result)
pub extern "C" fn moonpg_fformat(result : Result, col : Int) -> Int = "moonpg_fformat"

///|
#borrow(result)
pub extern "C" fn moonpg_cmdtuples(result : Result) -> Int64 = "moonpg_cmdtuples"

///|
#owned(result)
pub extern "C" fn moonpg_free_result(result : Result) -> Unit = "moonpg_free_result"

///|
#borrow(conn)
pub extern "C" fn moonpg_conn_is_null(conn : Connection) -> Int = "moonpg_conn_is_null"

///|
#borrow(result)
pub extern "C" fn moonpg_result_is_null(result : Result) -> Int = "moonpg_result_is_null"

///|
#borrow(name)
pub extern "C" fn moonpg_get_env_bytes(name : Bytes) -> Bytes = "moonpg_get_env_bytes"

///|
#borrow(conn)
pub extern "C" fn moonpg_server_version(conn : Connection) -> Int = "moonpg_server_version"

///|
#borrow(conn, sql)
pub extern "C" fn moonpg_execute(conn : Connection, sql : Bytes) -> Result = "moonpg_execute"

///|
#borrow(conn)
pub extern "C" fn moonpg_status(conn : Connection) -> Int = "moonpg_status"

///|
#borrow(conn, sql, values, lengths, formats, nulls)
pub extern "C" fn moonpg_query_params(
  conn : Connection,
  sql : Bytes,
  param_counts : Int,
  values : FixedArray[Bytes],
  lengths : FixedArray[Int],
  formats : FixedArray[Int],
  nulls : FixedArray[Bool],
) -> Result = "moonpg_query_params"

///|
#borrow(conn, sql, values, lengths, formats, nulls)
pub extern "C" fn moonpg_execute_params(
  conn : Connection,
  sql : Bytes,
  param_counts : Int,
  values : FixedArray[Bytes],
  lengths : FixedArray[Int],
  formats : FixedArray[Int],
  nulls : FixedArray[Bool],
) -> Result = "moonpg_execute_params"
