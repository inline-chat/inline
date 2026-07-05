import type { InlineSdkState } from "../sdk/types.js"

type StateJsonV1 = {
  version: 1
  dateCursor?: string
  lastSeqByChatId?: Record<string, number>
  lastSeqBySpaceId?: Record<string, number>
  lastUserSeq?: number
}

export const serializeStateV1 = (state: InlineSdkState): string => {
  const json: StateJsonV1 = {
    version: 1,
    ...(state.dateCursor != null ? { dateCursor: state.dateCursor.toString() } : {}),
    ...(state.lastSeqByChatId != null ? { lastSeqByChatId: state.lastSeqByChatId } : {}),
    ...(state.lastSeqBySpaceId != null ? { lastSeqBySpaceId: state.lastSeqBySpaceId } : {}),
    ...(state.lastUserSeq != null ? { lastUserSeq: state.lastUserSeq } : {}),
  }
  return JSON.stringify(json, null, 2)
}

export const deserializeStateV1 = (raw: string): InlineSdkState => {
  const parsed: unknown = JSON.parse(raw)
  if (!isStateJsonV1(parsed)) {
    throw new Error("invalid state json")
  }

  return {
    version: 1,
    ...(parsed.dateCursor != null ? { dateCursor: BigInt(parsed.dateCursor) } : {}),
    ...(parsed.lastSeqByChatId != null ? { lastSeqByChatId: parsed.lastSeqByChatId } : {}),
    ...(parsed.lastSeqBySpaceId != null ? { lastSeqBySpaceId: parsed.lastSeqBySpaceId } : {}),
    ...(parsed.lastUserSeq != null ? { lastUserSeq: parsed.lastUserSeq } : {}),
  }
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

const isSeqRecord = (value: unknown): value is Record<string, number> => {
  if (!isRecord(value)) return false
  for (const v of Object.values(value)) {
    if (typeof v !== "number" || !Number.isFinite(v)) return false
  }
  return true
}

const isStateJsonV1 = (value: unknown): value is StateJsonV1 => {
  if (!isRecord(value)) return false
  if (value.version !== 1) return false

  if (value.dateCursor != null && typeof value.dateCursor !== "string") return false

  if (value.lastSeqByChatId != null && !isSeqRecord(value.lastSeqByChatId)) return false
  if (value.lastSeqBySpaceId != null && !isSeqRecord(value.lastSeqBySpaceId)) return false
  if (value.lastUserSeq != null && (typeof value.lastUserSeq !== "number" || !Number.isFinite(value.lastUserSeq))) return false

  return true
}
