import { decode, encode } from "@msgpack/msgpack"
import { DbObjectKind, type DbModel } from "./models"
import { preparePersistedModel } from "./persisted-model"

const INLINE_MODEL_CODEC_VERSION = 1

type InlineModelEnvelope = {
  version: typeof INLINE_MODEL_CODEC_VERSION
  model: DbModel
}

export class InlineModelCodecError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = "InlineModelCodecError"
  }
}

const isDbObjectKind = (value: unknown): value is DbObjectKind =>
  typeof value === "string" &&
  Object.values(DbObjectKind).includes(value as DbObjectKind)

const isInlineModelEnvelope = (
  value: unknown,
): value is InlineModelEnvelope => {
  if (!value || typeof value !== "object") return false
  const envelope = value as Partial<InlineModelEnvelope>
  return (
    envelope.version === INLINE_MODEL_CODEC_VERSION &&
    !!envelope.model &&
    typeof envelope.model === "object" &&
    isDbObjectKind(envelope.model.kind) &&
    (typeof envelope.model.id === "string" ||
      typeof envelope.model.id === "number")
  )
}

export const encodeInlineModel = (model: DbModel): Uint8Array => {
  try {
    return encode(
      {
        version: INLINE_MODEL_CODEC_VERSION,
        model: preparePersistedModel(model),
      } satisfies InlineModelEnvelope,
      {
        useBigInt64: true,
        ignoreUndefined: true,
        sortKeys: true,
      },
    )
  } catch (cause) {
    throw new InlineModelCodecError(
      `Could not encode Inline ${model.kind} model ${String(model.id)}`,
      { cause },
    )
  }
}

export const decodeInlineModel = (payload: Uint8Array): DbModel => {
  let decoded: unknown
  try {
    decoded = decode(payload, {
      useBigInt64: true,
      maxStrLength: 16 * 1024 * 1024,
      maxBinLength: 64 * 1024 * 1024,
      maxArrayLength: 1_000_000,
      maxMapLength: 100_000,
      maxExtLength: 16 * 1024 * 1024,
    })
  } catch (cause) {
    throw new InlineModelCodecError(
      "Could not decode Inline model payload",
      { cause },
    )
  }

  if (!isInlineModelEnvelope(decoded)) {
    throw new InlineModelCodecError(
      "Unsupported or malformed Inline model payload",
    )
  }
  return decoded.model
}
