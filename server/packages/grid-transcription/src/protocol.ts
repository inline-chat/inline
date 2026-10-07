export type Model = "standard" | "meeting"

export type FinalTurn = Readonly<{ turnId: string; text: string }>

export class TranscriptionError extends Error {
  constructor(readonly code: "protocol" | "provider" | "overflow" | "stopped" | "expired" | "audio") {
    super(`Grid transcription ${code}`)
    this.name = "TranscriptionError"
  }
}

// A decoder is track/socket scoped. IDs are local admitted turns, never model speaker IDs.
export interface TurnDecoder {
  beginTurn(turnId: string): void
  accept(event: unknown): readonly FinalTurn[]
  close(): void
}

export function record(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new TranscriptionError("protocol")
  }
  return value as Record<string, unknown>
}

export function nonemptyString(value: unknown): string {
  if (typeof value !== "string" || value.length === 0 || value.length > 256) {
    throw new TranscriptionError("protocol")
  }
  return value
}

export const MAX_PENDING_TURNS = 2
export const MAX_TURN_TEXT_BYTES = 32 * 1024
