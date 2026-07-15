/** Largest signed 64-bit integer accepted by PostgreSQL `bigint` and protobuf `int64`. */
export const INT64_MAX = 9_223_372_036_854_775_807n

/** Smallest signed 64-bit integer accepted by PostgreSQL `bigint` and protobuf `int64`. */
export const INT64_MIN = -9_223_372_036_854_775_808n

export const MIN_SAFE_INTEGER = Number.MIN_SAFE_INTEGER
export const MAX_SAFE_INTEGER = Number.MAX_SAFE_INTEGER
export const MIN_POSITIVE_INTEGER = 1

/** Last whole Unix second in the four-digit RFC 3339 year range (`9999-12-31T23:59:59Z`). */
export const UNIX_TIMESTAMP_MAX_SECONDS = 253_402_300_799
