declare const inlineIdBrand: unique symbol

export type InlineIDKind =
  | "inline"
  | "user"
  | "chat"
  | "space"
  | "message"
  | "dialog"
  | "photo"
  | "file"

/**
 * Canonical signed int64 identity used by Inline domain/cache/route code.
 *
 * Protobuf uses bigint and SQLite stores INTEGER, but a decimal string is the
 * one lossless representation that also works naturally in URLs, JSON, and
 * IndexedDB keys.
 */
export type InlineID<K extends InlineIDKind = "inline"> = string & {
  readonly [inlineIdBrand]: K
}

export type UserID = InlineID<"user">
export type ChatID = InlineID<"chat">
export type SpaceID = InlineID<"space">
export type MessageID = InlineID<"message">
export type DialogID = InlineID<"dialog">
export type PhotoID = InlineID<"photo">
export type FileID = InlineID<"file">

export type InlineIDInput = string | number | bigint

export const int64Min = -(1n << 63n)
export const int64Max = (1n << 63n) - 1n

const signedDecimalPattern = /^(?:0|-[1-9]\d*|[1-9]\d*)$/

export class InvalidInlineID extends RangeError {
  constructor(value: unknown) {
    super(`Invalid Inline int64 ID: ${String(value)}`)
    this.name = "InvalidInlineID"
  }
}

const inputToBigInt = (value: InlineIDInput): bigint => {
  if (typeof value === "bigint") return value
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) throw new InvalidInlineID(value)
    return BigInt(value)
  }
  if (!signedDecimalPattern.test(value)) throw new InvalidInlineID(value)
  return BigInt(value)
}

export const inlineId = <K extends InlineIDKind = "inline">(
  value: InlineIDInput,
): InlineID<K> => {
  const exact = inputToBigInt(value)
  if (exact < int64Min || exact > int64Max) {
    throw new InvalidInlineID(value)
  }
  return exact.toString() as InlineID<K>
}

export const parseInlineId = <K extends InlineIDKind = "inline">(
  value: unknown,
  options: { positive?: boolean } = {},
): InlineID<K> | undefined => {
  if (
    typeof value !== "string" &&
    typeof value !== "number" &&
    typeof value !== "bigint"
  ) {
    return undefined
  }
  try {
    const parsed = inlineId<K>(value)
    if (options.positive && BigInt(parsed) <= 0n) return undefined
    return parsed
  } catch {
    return undefined
  }
}

export const protocolId = <K extends InlineIDKind>(
  value: InlineID<K>,
): bigint => BigInt(value)

export const compareInlineIds = <
  L extends InlineIDKind,
  R extends InlineIDKind,
>(
  left: InlineID<L>,
  right: InlineID<R>,
): number => {
  const lhs = BigInt(left)
  const rhs = BigInt(right)
  return lhs < rhs ? -1 : lhs > rhs ? 1 : 0
}

/**
 * Fixed-width unsigned offset that preserves signed int64 ordering when used
 * as a lexicographic IndexedDB string key.
 */
export const inlineIdOrderKey = <K extends InlineIDKind>(
  value: InlineID<K>,
): string =>
  (BigInt(value) - int64Min).toString().padStart(20, "0")

export const userId = (value: InlineIDInput): UserID =>
  inlineId<"user">(value)
export const chatId = (value: InlineIDInput): ChatID =>
  inlineId<"chat">(value)
export const spaceId = (value: InlineIDInput): SpaceID =>
  inlineId<"space">(value)
export const messageId = (value: InlineIDInput): MessageID =>
  inlineId<"message">(value)
export const dialogId = (value: InlineIDInput): DialogID =>
  inlineId<"dialog">(value)
export const photoId = (value: InlineIDInput): PhotoID =>
  inlineId<"photo">(value)
export const fileId = (value: InlineIDInput): FileID =>
  inlineId<"file">(value)
