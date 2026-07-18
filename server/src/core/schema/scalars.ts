import {
  Schema,
  SchemaGetter,
} from "effect"

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

const SafeIntegerString = Schema.String.check(
  Schema.isPattern(/^[+-]?[0-9]+$/),
).annotate({
  identifier: "SafeIntegerString",
  description:
    "A signed decimal integer string within JavaScript's safe-integer range",
  examples: ["42"],
})

/**
 * Query/path codec for a JSON-safe integer.
 *
 * Keeping the encoded string schema explicit prevents generated OpenAPI from
 * exposing Effect's broader JavaScript-number parser (decimals and exponents)
 * for integer-only transport fields.
 */
export const WireSafeIntegerFromString =
  SafeIntegerString.pipe(
    Schema.decodeTo(WireSafeInteger, {
      decode: SchemaGetter.transform((value) =>
        Number(value),
      ),
      encode: SchemaGetter.transform((value) =>
        String(value),
      ),
    }),
  ).annotate({
    identifier: "WireSafeIntegerFromString",
  })

/** JSON/body compatibility codec accepting an integer or integer string. */
export const WireSafeIntegerInput = Schema.Union([
  WireSafeInteger,
  WireSafeIntegerFromString,
]).annotate({
  identifier: "WireSafeIntegerInput",
  description:
    "A safe integer supplied as a JSON integer or decimal integer string",
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
