import { Buffer } from "node:buffer"
import {
  MAX_PENDING_TURNS,
  MAX_TURN_TEXT_BYTES,
  TranscriptionError,
  nonemptyString,
  record,
  type FinalTurn,
  type TurnDecoder,
} from "../protocol.js"

export const OPENAI_URL = "wss://api.openai.com/v1/realtime?intent=transcription"
export const OPENAI_SAMPLE_RATE = 24_000
// Retain IDs for the entire socket; eviction could mistake an old final for a new turn.
export const OPENAI_MAX_SOCKET_TURNS = 1024
const MAX_AUDIO_FRAME_BYTES = 64 * 1024

// https://developers.openai.com/api/docs/guides/realtime-transcription#transcribe-a-committed-turn
export function openAIConfiguration() {
  return {
    type: "session.update",
    session: {
      type: "transcription",
      audio: {
        input: {
          format: { type: "audio/pcm", rate: OPENAI_SAMPLE_RATE },
          transcription: { model: "gpt-transcribe" },
          turn_detection: null,
        },
      },
    },
  }
}

// Only a matching effective configuration makes the socket ready for microphone audio.
export function openAIConfigurationAccepted(value: unknown): boolean {
  const event = record(value)
  if (event.type !== "session.updated") return false
  const session = record(event.session)
  const input = record(record(session.audio).input)
  const format = record(input.format)
  const transcription = record(input.transcription)
  if (session.type !== "transcription" || format.type !== "audio/pcm"
    || format.rate !== OPENAI_SAMPLE_RATE || transcription.model !== "gpt-transcribe"
    || input.turn_detection !== null) {
    throw new TranscriptionError("protocol")
  }
  return true
}

export function openAIAppendAudio(pcm: Uint8Array) {
  if (pcm.byteLength === 0 || pcm.byteLength % 2 !== 0 || pcm.byteLength > MAX_AUDIO_FRAME_BYTES) {
    throw new TranscriptionError("audio")
  }
  return { type: "input_audio_buffer.append", audio: Buffer.from(pcm).toString("base64") }
}

export function openAICommit() {
  return { type: "input_audio_buffer.commit" }
}

type PendingTurn = { turnId: string; itemId?: string; text?: string }

export class OpenAITurnDecoder implements TurnDecoder {
  private closed = false
  private readonly turns: PendingTurn[] = []
  private readonly localIds = new Set<string>()
  private readonly itemIds = new Set<string>()
  private readonly earlyFinals = new Map<string, string>()
  private lastItemId: string | null = null

  beginTurn(turnId: string): void {
    this.assertOpen()
    try {
      nonemptyString(turnId)
      if (this.localIds.has(turnId)) throw new TranscriptionError("protocol")
      if (this.turns.length >= MAX_PENDING_TURNS || this.localIds.size >= OPENAI_MAX_SOCKET_TURNS) {
        throw new TranscriptionError("overflow")
      }
      this.localIds.add(turnId)
      this.turns.push({ turnId })
    } catch (error) {
      this.fail(error)
    }
  }

  accept(value: unknown): readonly FinalTurn[] {
    this.assertOpen()
    try {
      const event = record(value)
      const type = nonemptyString(event.type)
      switch (type) {
        case "error":
        case "conversation.item.input_audio_transcription.failed":
          throw new TranscriptionError("provider")
        case "input_audio_buffer.committed":
          return this.committed(event)
        case "conversation.item.input_audio_transcription.completed":
          return this.completed(event)
        case "session.created":
        case "session.updated":
        case "transcription_session.created":
        case "transcription_session.updated":
        case "conversation.created":
        case "conversation.item.created":
        case "conversation.item.added":
        case "conversation.item.done":
        case "conversation.item.input_audio_transcription.delta":
        case "conversation.item.input_audio_transcription.segment":
        case "rate_limits.updated":
          return []
        default:
          throw new TranscriptionError("protocol")
      }
    } catch (error) {
      return this.fail(error)
    }
  }

  close(): void {
    this.closed = true
    this.turns.length = 0
    this.localIds.clear()
    this.itemIds.clear()
    this.earlyFinals.clear()
    this.lastItemId = null
  }

  private committed(event: Record<string, unknown>): readonly FinalTurn[] {
    const itemId = nonemptyString(event.item_id)
    const previous = event.previous_item_id
    if (previous !== undefined && previous !== null) nonemptyString(previous)
    if (this.itemIds.has(itemId)) return []
    // Manual commits are admitted FIFO. A conflicting predecessor makes that mapping unsafe.
    if (previous !== undefined && previous !== this.lastItemId) throw new TranscriptionError("protocol")
    const turn = this.turns.find((candidate) => candidate.itemId === undefined)
    if (!turn) throw new TranscriptionError("protocol")
    if (this.itemIds.size >= OPENAI_MAX_SOCKET_TURNS) throw new TranscriptionError("overflow")
    turn.itemId = itemId
    this.itemIds.add(itemId)
    this.lastItemId = itemId
    const early = this.earlyFinals.get(itemId)
    if (early !== undefined) {
      turn.text = early
      this.earlyFinals.delete(itemId)
    }
    if (this.earlyFinals.size > this.turns.filter((candidate) => candidate.itemId === undefined).length) {
      throw new TranscriptionError("protocol")
    }
    return this.drain()
  }

  private completed(event: Record<string, unknown>): readonly FinalTurn[] {
    const itemId = nonemptyString(event.item_id)
    if (event.content_index !== 0 || typeof event.transcript !== "string") {
      throw new TranscriptionError("protocol")
    }
    if (event.transcript.length > MAX_TURN_TEXT_BYTES || Buffer.byteLength(event.transcript) > MAX_TURN_TEXT_BYTES) {
      throw new TranscriptionError("overflow")
    }
    const turn = this.turns.find((candidate) => candidate.itemId === itemId)
    if (turn) {
      // A duplicate final cannot revise an already accepted final, even while blocked behind an earlier turn.
      if (turn.text === undefined) turn.text = event.transcript
      return this.drain()
    }
    if (this.itemIds.has(itemId) || this.earlyFinals.has(itemId)) return []
    const unacknowledged = this.turns.filter((candidate) => candidate.itemId === undefined).length
    if (unacknowledged === 0) throw new TranscriptionError("protocol")
    if (this.earlyFinals.size >= unacknowledged || this.earlyFinals.size >= MAX_PENDING_TURNS) {
      throw new TranscriptionError("overflow")
    }
    this.earlyFinals.set(itemId, event.transcript)
    return []
  }

  private drain(): readonly FinalTurn[] {
    const result: FinalTurn[] = []
    while (this.turns[0]?.text !== undefined) {
      const turn = this.turns.shift()
      if (!turn || turn.text === undefined) throw new TranscriptionError("protocol")
      const text = turn.text.trim()
      result.push({ turnId: turn.turnId, text })
    }
    return result
  }

  private assertOpen(): void {
    if (this.closed) throw new TranscriptionError("stopped")
  }

  private fail(error: unknown): never {
    this.close()
    throw error instanceof TranscriptionError ? error : new TranscriptionError("protocol")
  }
}
