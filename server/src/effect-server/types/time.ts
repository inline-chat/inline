import { Schema } from "effect"
import { UNIX_TIMESTAMP_MAX_SECONDS } from "../constants"
import { NonNegativeInt } from "./numbers"

/** Unix time in whole seconds, bounded to the four-digit RFC 3339 year range. */
export const TimestampSeconds = NonNegativeInt.check(
  Schema.isLessThanOrEqualTo(UNIX_TIMESTAMP_MAX_SECONDS),
).pipe(Schema.brand("inline/TimestampSeconds"))
export type TimestampSeconds = typeof TimestampSeconds.Type

/** A non-negative whole-second duration. */
export const DurationSeconds = NonNegativeInt.pipe(Schema.brand("inline/DurationSeconds"))
export type DurationSeconds = typeof DurationSeconds.Type
