export type InlineUnixSeconds = bigint

// Accepting `number` is a convenience for callers. All SDK outputs are `bigint`.
// Keeping this centralized makes it easy to do a breaking change later (e.g. to `string`).
export type InlineUnixSecondsLike = InlineUnixSeconds | number

export class InlineUnixSecondsError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "InlineUnixSecondsError"
  }
}

export const asInlineUnixSeconds = (value: InlineUnixSecondsLike, fieldName = "unixSeconds"): InlineUnixSeconds => {
  if (typeof value === "bigint") return value
  if (typeof value !== "number") {
    throw new InlineUnixSecondsError(`invalid ${fieldName}: expected number|bigint`)
  }
  if (!Number.isSafeInteger(value)) {
    throw new InlineUnixSecondsError(`invalid ${fieldName}: number must be a safe integer`)
  }
  return BigInt(value)
}

