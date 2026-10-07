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

export const SONIOX_URL = "wss://stt-rt.soniox.com/transcribe-websocket"
export const SONIOX_SAMPLE_RATE = 16_000
export const SONIOX_MAX_SOCKET_TURNS = 1024
const MAX_AUDIO_FRAME_BYTES = 64 * 1024

// https://soniox.com/docs/api-reference/stt/websocket-api
// This initial wire message contains a secret; the transport must never log it.
export function sonioxConfiguration(apiKey: string) {
  nonemptyString(apiKey)
  return {
    api_key: apiKey,
    model: "stt-rt-v5",
    audio_format: "pcm_s16le",
    sample_rate: SONIOX_SAMPLE_RATE,
    num_channels: 1,
    enable_speaker_diarization: false,
    enable_endpoint_detection: false,
  }
}

export function sonioxAudio(pcm: Uint8Array): Uint8Array {
  if (pcm.byteLength === 0 || pcm.byteLength % 2 !== 0 || pcm.byteLength > MAX_AUDIO_FRAME_BYTES) {
    throw new TranscriptionError("audio")
  }
  return pcm.slice()
}

export function sonioxFinalize() {
  return { type: "finalize" }
}

export function sonioxKeepalive() {
  return { type: "keepalive" }
}

export class SonioxTurnDecoder implements TurnDecoder {
  private closed = false
  private readonly turns: string[] = []
  private readonly localIds = new Set<string>()
  private text = ""
  private textBytes = 0

  beginTurn(turnId: string): void {
    this.assertOpen()
    try {
      nonemptyString(turnId)
      if (this.localIds.has(turnId)) throw new TranscriptionError("protocol")
      if (this.turns.length >= MAX_PENDING_TURNS || this.localIds.size >= SONIOX_MAX_SOCKET_TURNS) {
        throw new TranscriptionError("overflow")
      }
      this.localIds.add(turnId)
      this.turns.push(turnId)
    } catch (error) {
      this.fail(error)
    }
  }

  // Final tokens can precede beginTurn: admission must occur immediately before sending finalize.
  // The provider promises ordered, unrepeated final tokens; real socket qualification remains required.
  accept(value: unknown): readonly FinalTurn[] {
    this.assertOpen()
    try {
      const event = record(value)
      if (event.error_code !== undefined || event.error_type !== undefined) {
        throw new TranscriptionError("provider")
      }
      if (!Array.isArray(event.tokens) || event.tokens.length > MAX_TURN_TEXT_BYTES) {
        throw new TranscriptionError(Array.isArray(event.tokens) ? "overflow" : "protocol")
      }
      if (event.finished !== undefined && typeof event.finished !== "boolean") {
        throw new TranscriptionError("protocol")
      }
      const result: FinalTurn[] = []
      for (const value of event.tokens) {
        const token = record(value)
        if (typeof token.is_final !== "boolean" || typeof token.text !== "string") {
          throw new TranscriptionError("protocol")
        }
        if (!token.is_final) continue
        if (token.text === "<end>") throw new TranscriptionError("protocol")
        if (token.text === "<fin>") {
          const turnId = this.turns.shift()
          if (turnId === undefined) throw new TranscriptionError("protocol")
          const text = this.text.trim()
          result.push({ turnId, text })
          this.text = ""
          this.textBytes = 0
          continue
        }
        if (token.text.length > MAX_TURN_TEXT_BYTES) throw new TranscriptionError("overflow")
        const bytes = Buffer.byteLength(token.text)
        if (this.textBytes + bytes > MAX_TURN_TEXT_BYTES) throw new TranscriptionError("overflow")
        this.text += token.text
        this.textBytes += bytes
      }
      if (event.finished === true) {
        if (this.turns.length > 0 || this.textBytes > 0) throw new TranscriptionError("protocol")
        this.close()
      }
      return result
    } catch (error) {
      return this.fail(error)
    }
  }

  close(): void {
    this.closed = true
    this.turns.length = 0
    this.localIds.clear()
    this.text = ""
    this.textBytes = 0
  }

  private assertOpen(): void {
    if (this.closed) throw new TranscriptionError("stopped")
  }

  private fail(error: unknown): never {
    this.close()
    throw error instanceof TranscriptionError ? error : new TranscriptionError("protocol")
  }
}
