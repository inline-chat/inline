/**
 * Match JSON object serialization before validating compatibility responses.
 *
 * JSON.stringify omits object properties whose value is undefined. Retained
 * handlers and TypeBox encoders can preserve those properties in memory, while
 * Effect's exact optional schemas correctly reject a present undefined value.
 * Keep every other value unchanged so contract validation still catches null,
 * scalar, array, branded-ID, and timestamp mismatches.
 */
export const omitUndefinedObjectProperties = (
  value: unknown,
): unknown => {
  if (Array.isArray(value)) {
    return value.map(omitUndefinedObjectProperties)
  }
  if (
    value === null
    || typeof value !== "object"
    || Object.getPrototypeOf(value) !== Object.prototype
  ) {
    return value
  }

  return Object.fromEntries(
    Object.entries(value)
      .filter(([, property]) => property !== undefined)
      .map(([key, property]) => [
        key,
        omitUndefinedObjectProperties(property),
      ]),
  )
}
