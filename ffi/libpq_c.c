#include "moonbit.h"
#include <libpq-fe.h>
#include <stdlib.h>
#include <string.h>

// Opaque wrapper structs for MoonBit #extern types
typedef struct {
  PGconn *conn;
} moonpg_Connection;

typedef struct {
  PGresult *result;
} moonpg_Result;

// --- Connection ---

void *moonpg_connect(const char *conninfo) {
  PGconn *conn = PQconnectdb(conninfo);
  if (conn == NULL) {
    return NULL;
  }
  moonpg_Connection *mc = (moonpg_Connection *)malloc(sizeof(moonpg_Connection));
  mc->conn = conn;
  return (void *)mc;
}

void *moonpg_query(void *conn_ptr, const char *sql) {
  moonpg_Connection *mc = (moonpg_Connection *)conn_ptr;
  PGresult *res = PQexec(mc->conn, sql);
  ExecStatusType status = PQresultStatus(res);
  if (status != PGRES_TUPLES_OK && status != PGRES_COMMAND_OK) {
    PQclear(res);
    return NULL;
  }
  moonpg_Result *mr = (moonpg_Result *)malloc(sizeof(moonpg_Result));
  mr->result = res;
  return (void *)mr;
}

void moonpg_close(void *conn_ptr) {
  moonpg_Connection *mc = (moonpg_Connection *)conn_ptr;
  PQfinish(mc->conn);
  free(mc);
}

// --- Error handling ---

moonbit_bytes_t moonpg_error_message_bytes(void *conn_ptr) {
  moonpg_Connection *mc = (moonpg_Connection *)conn_ptr;
  const char *err = PQerrorMessage(mc->conn);
  int len = strlen(err);
  uint8_t *result = moonbit_make_bytes_raw(len);
  memcpy(result, err, len);
  return result;
}

// --- Result accessors ---

int32_t moonpg_ntuples(void *result_ptr) {
  moonpg_Result *mr = (moonpg_Result *)result_ptr;
  return PQntuples(mr->result);
}

int32_t moonpg_nfields(void *result_ptr) {
  moonpg_Result *mr = (moonpg_Result *)result_ptr;
  return PQnfields(mr->result);
}

uint8_t *moonpg_getvalue_bytes(void *result_ptr, int32_t row, int32_t col) {
  moonpg_Result *mr = (moonpg_Result *)result_ptr;
  if (PQgetisnull(mr->result, row, col)) {
    return moonbit_make_bytes(0, 0);
  }
  const char *val = PQgetvalue(mr->result, row, col);
  int len = PQgetlength(mr->result, row, col);
  uint8_t *result = moonbit_make_bytes_raw(len);
  memcpy(result, val, len);
  return result;
}

moonbit_bytes_t moonpg_fname_bytes(void *result_ptr, int32_t col) {
  moonpg_Result *mr = (moonpg_Result *)result_ptr;
  const char *name = PQfname(mr->result, col);
  int len = strlen(name);
  uint8_t *result = moonbit_make_bytes_raw(len);
  memcpy(result, name, len);
  return result;
}

int32_t moonpg_getisnull(void *result_ptr, int32_t row, int32_t col) {
  moonpg_Result *mr = (moonpg_Result *)result_ptr;
  return PQgetisnull(mr->result, row, col);
}

int64_t moonpg_cmdtuples(void *result_ptr) {
  moonpg_Result *mr = (moonpg_Result *)result_ptr;
  char *val = PQcmdTuples(mr->result);
  return atol(val);
}

void moonpg_free_result(void *result_ptr) {
  moonpg_Result *mr = (moonpg_Result *)result_ptr;
  PQclear(mr->result);
  free(mr);
}

// --- Null checks ---

int32_t moonpg_conn_is_null(void *conn_ptr) {
  return conn_ptr == NULL ? 1 : 0;
}

int32_t moonpg_result_is_null(void *result_ptr) {
  return result_ptr == NULL ? 1 : 0;
}

// --- Environment ---

moonbit_bytes_t moonpg_get_env_bytes(const char *name) {
  const char *val = getenv(name);
  if (val == NULL) {
    return moonbit_make_bytes(0, 0);
  }
  int len = strlen(val);
  uint8_t *result = moonbit_make_bytes_raw(len);
  memcpy(result, val, len);
  return result;
}

// --- Execute (non-SELECT) ---

void *moonpg_execute(void *conn_ptr, const char *sql) {
  moonpg_Connection *mc = (moonpg_Connection *)conn_ptr;
  PGresult *res = PQexec(mc->conn, sql);
  ExecStatusType status = PQresultStatus(res);
  if (status != PGRES_COMMAND_OK && status != PGRES_TUPLES_OK) {
    PQclear(res);
    return NULL;
  }
  moonpg_Result *mr = (moonpg_Result *)malloc(sizeof(moonpg_Result));
  mr->result = res;
  return (void *)mr;
}

// --- Parameterized queries ---


// Shared implementation for parameterized queries.
// `nulls` is a FixedArray[Bool] from MoonBit, passed as a pointer to a byte
// array where each byte is 0 (false) or non-zero (true).
static void *moonpg_exec_params_impl(
    void *conn_ptr,
    const char *sql,
    int32_t param_count,
    const char **values,
    int32_t *lengths,
    int32_t *formats,
    uint8_t *nulls) {
  moonpg_Connection *mc = (moonpg_Connection *)conn_ptr;

  // Allocate libpq-shaped parameter arrays (PQexecParams mutates the lengths
  // and formats arrays in place, so we need to make local copies).
  const char **param_values = (const char **)malloc(sizeof(char *) * param_count);
  int *param_lengths = (int *)malloc(sizeof(int) * param_count);
  int *param_formats = (int *)malloc(sizeof(int) * param_count);

  for (int i = 0; i < param_count; i++) {
    if (nulls[i]) {
      param_values[i] = NULL;
      param_lengths[i] = 0;
      param_formats[i] = 0;
    } else {
      param_values[i] = values[i];
      param_lengths[i] = (int)lengths[i];
      param_formats[i] = (int)formats[i];
    }
  }

  PGresult *res = PQexecParams(
      mc->conn,
      sql,
      param_count,
      NULL,            // paramTypes: let server infer
      param_values,    // paramValues
      param_lengths,   // paramLengths
      param_formats,   // paramFormats: 0=text, 1=binary
      0);              // resultFormat: text

  free(param_values);
  free(param_lengths);
  free(param_formats);

  ExecStatusType status = PQresultStatus(res);
  if (status != PGRES_TUPLES_OK && status != PGRES_COMMAND_OK) {
    PQclear(res);
    return NULL;
  }

  moonpg_Result *mr = (moonpg_Result *)malloc(sizeof(moonpg_Result));
  if (mr == NULL) {
    PQclear(res);
    return NULL;
  }
  mr->result = res;
  return (void *)mr;
}

void *moonpg_query_params(
    void *conn_ptr,
    const char *sql,
    int32_t param_count,
    const char **values,
    int32_t *lengths,
    int32_t *formats,
    uint8_t *nulls) {
  return moonpg_exec_params_impl(
      conn_ptr, sql, param_count, values, lengths, formats, nulls);
}

void *moonpg_execute_params(
    void *conn_ptr,
    const char *sql,
    int32_t param_count,
    const char **values,
    int32_t *lengths,
    int32_t *formats,
    uint8_t *nulls) {
  return moonpg_exec_params_impl(
      conn_ptr, sql, param_count, values, lengths, formats, nulls);
}

// --- Server version ---

int32_t moonpg_server_version(void *conn_ptr) {
  moonpg_Connection *mc = (moonpg_Connection *)conn_ptr;
  return PQserverVersion(mc->conn);
}

// --- Connection status ---

int32_t moonpg_status(void *conn_ptr) {
  moonpg_Connection *mc = (moonpg_Connection *)conn_ptr;
  return (int32_t)PQstatus(mc->conn);
}
