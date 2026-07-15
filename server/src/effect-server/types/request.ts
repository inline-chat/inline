import { Schema } from "effect"
import { REQUEST_ID_MAX_LENGTH, REQUEST_ID_PATTERN } from "../constants"

export const RequestId = Schema.String.check(
  Schema.isTrimmed(),
  Schema.isMinLength(1),
  Schema.isMaxLength(REQUEST_ID_MAX_LENGTH),
  Schema.isPattern(REQUEST_ID_PATTERN),
).pipe(Schema.brand("inline/RequestId"))
export type RequestId = typeof RequestId.Type

const BearerTokenValue = Schema.String.check(Schema.isTrimmed(), Schema.isMinLength(1)).pipe(
  Schema.brand("inline/BearerToken"),
)

/** A normalized bearer credential that cannot be generically encoded back to plaintext. */
export const BearerToken = Schema.RedactedFromValue(BearerTokenValue, { disallowEncode: true })
export type BearerToken = typeof BearerToken.Type
