///|
/// `FromRow` implementations for built-in types and tuples,
/// plus `fetch` / `fetch_one` extension methods on `&QueryExecutor`.

// ===========================================================================
// FromRow — built-in type implementations
// ===========================================================================

///|
/// Read a single-column row as `Int`.
pub impl FromRow for Int with fn from_row(r : Row) -> Int raise PgError {
  r.get(0)
}

///|
/// Read a single-column row as `Int64`.
pub impl FromRow for Int64 with fn from_row(r : Row) -> Int64 raise PgError {
  r.get(0)
}

///|
/// Read a single-column row as `Double`.
pub impl FromRow for Double with fn from_row(r : Row) -> Double raise PgError {
  r.get(0)
}

///|
/// Read a single-column row as `Bool`.
pub impl FromRow for Bool with fn from_row(r : Row) -> Bool raise PgError {
  r.get(0)
}

///|
/// Read a single-column row as `String`.
pub impl FromRow for String with fn from_row(r : Row) -> String raise PgError {
  r.get(0)
}

///|
/// Read a single-column row as `Bytes`.
pub impl FromRow for Bytes with fn from_row(r : Row) -> Bytes raise PgError {
  r.get(0)
}

///|
/// Read a single-column row as `Json`.
pub impl FromRow for Json with fn from_row(r : Row) -> Json raise PgError {
  r.get(0)
}

///|
/// Read a single-column row as an optional `T`.
///
/// `None` is returned when the database value is SQL NULL.
pub impl[T : FromValue] FromRow for T? with fn from_row(r : Row) -> T? raise PgError {
  r.get(0)
}

///|
/// Read a single-column row as `Timestamp`.
pub impl FromRow for Timestamp with fn from_row(r : Row) -> Timestamp raise PgError {
  r.get(0)
}

///|
/// Read a single-column row as `Decimal`.
pub impl FromRow for @decimal.Decimal with fn from_row(r : Row) -> @decimal.Decimal raise PgError {
  r.get(0)
}

///|
/// Read a single-column row as `UUID`.
pub impl FromRow for @uuid.UUID with fn from_row(r : Row) -> @uuid.UUID raise PgError {
  r.get(0)
}

// ===========================================================================
// FromRow — tuple implementations (2-tuple through 10-tuple)
// ===========================================================================

///|
pub impl[A : FromValue, B : FromValue] FromRow for (A, B) with fn from_row(
  r : Row,
) -> (A, B) raise PgError {
  (r.get(0), r.get(1))
}

///|
pub impl[A : FromValue, B : FromValue, C : FromValue] FromRow for (A, B, C) with fn from_row(
  r : Row,
) -> (A, B, C) raise PgError {
  (r.get(0), r.get(1), r.get(2))
}

///|
pub impl[A : FromValue, B : FromValue, C : FromValue, D : FromValue] FromRow for (
  A,
  B,
  C,
  D,
) with fn from_row(r : Row) -> (A, B, C, D) raise PgError {
  (r.get(0), r.get(1), r.get(2), r.get(3))
}

///|
pub impl[
  A : FromValue,
  B : FromValue,
  C : FromValue,
  D : FromValue,
  E : FromValue,
] FromRow for (A, B, C, D, E) with fn from_row(r : Row) -> (A, B, C, D, E) raise PgError {
  (r.get(0), r.get(1), r.get(2), r.get(3), r.get(4))
}

///|
pub impl[
  A : FromValue,
  B : FromValue,
  C : FromValue,
  D : FromValue,
  E : FromValue,
  F : FromValue,
] FromRow for (A, B, C, D, E, F) with fn from_row(r : Row) -> (A, B, C, D, E, F) raise PgError {
  (r.get(0), r.get(1), r.get(2), r.get(3), r.get(4), r.get(5))
}

///|
pub impl[
  A : FromValue,
  B : FromValue,
  C : FromValue,
  D : FromValue,
  E : FromValue,
  F : FromValue,
  G : FromValue,
] FromRow for (A, B, C, D, E, F, G) with fn from_row(r : Row) -> (
  A,
  B,
  C,
  D,
  E,
  F,
  G,
) raise PgError {
  (r.get(0), r.get(1), r.get(2), r.get(3), r.get(4), r.get(5), r.get(6))
}

///|
pub impl[
  A : FromValue,
  B : FromValue,
  C : FromValue,
  D : FromValue,
  E : FromValue,
  F : FromValue,
  G : FromValue,
  H : FromValue,
] FromRow for (A, B, C, D, E, F, G, H) with fn from_row(r : Row) -> (
  A,
  B,
  C,
  D,
  E,
  F,
  G,
  H,
) raise PgError {
  (
    r.get(0),
    r.get(1),
    r.get(2),
    r.get(3),
    r.get(4),
    r.get(5),
    r.get(6),
    r.get(7),
  )
}

///|
pub impl[
  A : FromValue,
  B : FromValue,
  C : FromValue,
  D : FromValue,
  E : FromValue,
  F : FromValue,
  G : FromValue,
  H : FromValue,
  I : FromValue,
] FromRow for (A, B, C, D, E, F, G, H, I) with fn from_row(r : Row) -> (
  A,
  B,
  C,
  D,
  E,
  F,
  G,
  H,
  I,
) raise PgError {
  (
    r.get(0),
    r.get(1),
    r.get(2),
    r.get(3),
    r.get(4),
    r.get(5),
    r.get(6),
    r.get(7),
    r.get(8),
  )
}

///|
pub impl[
  A : FromValue,
  B : FromValue,
  C : FromValue,
  D : FromValue,
  E : FromValue,
  F : FromValue,
  G : FromValue,
  H : FromValue,
  I : FromValue,
  J : FromValue,
] FromRow for (A, B, C, D, E, F, G, H, I, J) with fn from_row(r : Row) -> (
  A,
  B,
  C,
  D,
  E,
  F,
  G,
  H,
  I,
  J,
) raise PgError {
  (
    r.get(0),
    r.get(1),
    r.get(2),
    r.get(3),
    r.get(4),
    r.get(5),
    r.get(6),
    r.get(7),
    r.get(8),
    r.get(9),
  )
}
