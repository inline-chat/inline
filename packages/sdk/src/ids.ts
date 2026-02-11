export type InlineId = bigint

// Accepting `number` is a convenience for callers. All SDK outputs are `bigint`.
// Keeping this centralized makes it easy to do a breaking change later (e.g. to `string`).
export type InlineIdLike = InlineId | number

export class InlineIdError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "InlineIdError"
  }
}

export const asInlineId = (value: InlineIdLike, fieldName = "id"): InlineId => {
  if (typeof value === "bigint") return value
  if (typeof value !== "number") {
    throw new InlineIdError(`invalid ${fieldName}: expected number|bigint`)
  }
  if (!Number.isSafeInteger(value)) {
    throw new InlineIdError(`invalid ${fieldName}: number must be a safe integer`)
  }
  return BigInt(value)
}

