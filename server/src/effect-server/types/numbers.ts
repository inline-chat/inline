import { Schema } from "effect"
import {
  INT64_MAX,
  INT64_MIN,
  MAX_SAFE_INTEGER,
  MIN_POSITIVE_INTEGER,
  MIN_SAFE_INTEGER,
} from "../constants"

export const SafeInt = Schema.Int.check(
  Schema.isBetween({ minimum: MIN_SAFE_INTEGER, maximum: MAX_SAFE_INTEGER }),
).pipe(Schema.brand("inline/SafeInt"))
export type SafeInt = typeof SafeInt.Type

export const NonNegativeInt = SafeInt.check(Schema.isGreaterThanOrEqualTo(0)).pipe(
  Schema.brand("inline/NonNegativeInt"),
)
export type NonNegativeInt = typeof NonNegativeInt.Type

export const PositiveInt = SafeInt.check(Schema.isGreaterThanOrEqualTo(MIN_POSITIVE_INTEGER)).pipe(
  Schema.brand("inline/PositiveInt"),
)
export type PositiveInt = typeof PositiveInt.Type

export const Int32 = Schema.Number.check(Schema.isInt32()).pipe(Schema.brand("inline/Int32"))
export type Int32 = typeof Int32.Type

export const PositiveInt32 = Int32.check(Schema.isGreaterThanOrEqualTo(MIN_POSITIVE_INTEGER)).pipe(
  Schema.brand("inline/PositiveInt32"),
)
export type PositiveInt32 = typeof PositiveInt32.Type

export const Int64 = Schema.BigInt.check(Schema.isBetweenBigInt({ minimum: INT64_MIN, maximum: INT64_MAX })).pipe(
  Schema.brand("inline/Int64"),
)
export type Int64 = typeof Int64.Type

export const PositiveInt64 = Int64.check(Schema.isGreaterThanBigInt(0n)).pipe(Schema.brand("inline/PositiveInt64"))
export type PositiveInt64 = typeof PositiveInt64.Type
