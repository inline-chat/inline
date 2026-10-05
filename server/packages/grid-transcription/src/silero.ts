import { createHash } from "node:crypto"
import { readFile } from "node:fs/promises"
import { AudioFrame, AudioResampler, AudioResamplerQuality } from "@livekit/rtc-node"
import { InferenceSession, Tensor } from "onnxruntime-node"
import { TranscriptionError } from "./protocol.js"

export const SILERO_MODEL_SHA256 = "1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3"
export interface SpeechDetector { probability(samples: Int16Array): Promise<number>; close(): void }

// Model tensor contract follows LiveKit's Apache-2.0 onnx_model.ts, pinned plugin 1.9.1.
// The upstream Silero model and its MIT license are vendored alongside this file.
export class SileroModel {
  private constructor(private readonly session: InferenceSession) {}

  static async load(): Promise<SileroModel> {
    try {
      const bytes = await readFile(new URL("./silero_vad.onnx", import.meta.url))
      if (createHash("sha256").update(bytes).digest("hex") !== SILERO_MODEL_SHA256) {
        throw new TranscriptionError("protocol")
      }
      const session = await InferenceSession.create(bytes, {
        interOpNumThreads: 1, intraOpNumThreads: 1, executionMode: "sequential",
        executionProviders: ["cpu"],
      })
      return new SileroModel(session)
    } catch (error) {
      throw error instanceof TranscriptionError ? error : new TranscriptionError("audio")
    }
  }

  detector(sampleRate: number): SpeechDetector { return new SileroDetector(this.session, sampleRate) }
  async close(): Promise<void> { await this.session.release() }
}

class SileroDetector implements SpeechDetector {
  private readonly resampler: AudioResampler | undefined
  private readonly context = new Float32Array(64)
  private readonly state = new Float32Array(256)
  private readonly window = new Float32Array(512)
  private readonly input = new Float32Array(576)
  private windowLength = 0
  private lastProbability = 0
  private closed = false
  private busy = false

  constructor(private readonly session: InferenceSession, private readonly sampleRate: number) {
    if (sampleRate !== 16_000 && sampleRate !== 24_000) throw new TranscriptionError("audio")
    if (sampleRate !== 16_000) this.resampler = new AudioResampler(sampleRate, 16_000, 1, AudioResamplerQuality.QUICK)
  }

  async probability(samples: Int16Array): Promise<number> {
    if (this.closed) throw new TranscriptionError("stopped")
    if (this.busy || samples.length === 0 || samples.length > this.sampleRate / 10) {
      throw new TranscriptionError("audio")
    }
    this.busy = true
    try {
      const frames = this.resampler
        ? this.resampler.push(new AudioFrame(samples, this.sampleRate, 1, samples.length))
        : [new AudioFrame(samples, 16_000, 1, samples.length)]
      for (const frame of frames) {
        for (const sample of frame.data) {
          this.window[this.windowLength++] = sample / 32768
          if (this.windowLength !== 512) continue
          this.input.set(this.context)
          this.input.set(this.window, 64)
          const output = await this.session.run({
            input: new Tensor("float32", this.input, [1, 576]),
            state: new Tensor("float32", this.state, [2, 1, 128]),
            sr: new Tensor("int64", BigInt64Array.of(16_000n)),
          })
          if (this.closed) throw new TranscriptionError("stopped")
          const next = output.stateN?.data
          const probability = output.output?.data
          if (!(next instanceof Float32Array) || next.length !== 256
            || !(probability instanceof Float32Array) || probability.length !== 1
            || !Number.isFinite(probability[0]) || probability[0]! < 0 || probability[0]! > 1) {
            throw new TranscriptionError("audio")
          }
          this.state.set(next)
          this.context.set(this.input.subarray(512))
          this.lastProbability = probability[0]!
          this.windowLength = 0
        }
      }
      return this.lastProbability
    } catch (error) {
      throw error instanceof TranscriptionError ? error : new TranscriptionError("audio")
    } finally { this.busy = false }
  }

  close(): void {
    if (this.closed) return
    this.closed = true
    this.resampler?.close()
    this.context.fill(0)
    this.state.fill(0)
    this.window.fill(0)
    this.input.fill(0)
  }
}
