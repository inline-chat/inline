import { Schema } from "effect"

const safeIntegerRange = Schema.isBetween({
  minimum: Number.MIN_SAFE_INTEGER,
  maximum: Number.MAX_SAFE_INTEGER,
})

const nonNegativeSafeIntegerRange = Schema.isBetween({
  minimum: 0,
  maximum: Number.MAX_SAFE_INTEGER,
})

const positiveSafeIntegerRange = Schema.isBetween({
  minimum: 1,
  maximum: Number.MAX_SAFE_INTEGER,
})

const httpStatusRange = Schema.isBetween({
  minimum: 100,
  maximum: 599,
})

/** JSON-safe integer with no nominal meaning. */
export const WireSafeInteger = Schema.Int.check(safeIntegerRange).annotate({
  identifier: "WireSafeInteger",
  description: "An integer that can be represented exactly by a JavaScript number",
})

/** JSON-safe non-negative integer with no nominal meaning. */
export const WireNonNegativeInteger = Schema.Int.check(nonNegativeSafeIntegerRange).annotate({
  identifier: "WireNonNegativeInteger",
  description: "A non-negative integer that can be represented exactly by a JavaScript number",
})

/** JSON-safe positive integer with no nominal meaning. */
export const WirePositiveInteger = Schema.Int.check(positiveSafeIntegerRange).annotate({
  identifier: "WirePositiveInteger",
  description: "A positive integer that can be represented exactly by a JavaScript number",
})

/** Standard three-digit HTTP status code. */
export const HttpStatusCode = Schema.Int.check(httpStatusRange).annotate({
  identifier: "HttpStatusCode",
  description: "A standard HTTP response status code from 100 through 599",
})

/** Nominal Inline entity identifier. Use the unbranded wire schema in neutral public DTOs. */
export const InlineId = WirePositiveInteger.pipe(Schema.brand("InlineId")).annotate({
  identifier: "InlineId",
  description: "A positive Inline entity identifier",
})

export type InlineId = typeof InlineId.Type

/** Nominal Unix timestamp measured in whole seconds. */
export const UnixSeconds = WireNonNegativeInteger.pipe(Schema.brand("UnixSeconds")).annotate({
  identifier: "UnixSeconds",
  description: "A Unix timestamp measured in whole seconds",
})

export type UnixSeconds = typeof UnixSeconds.Type
