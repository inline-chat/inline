import { TranscriptionError } from "./protocol.js"

export type SpeechAction = Readonly<{ kind: "start"; frames: readonly Int16Array[] }>
  | Readonly<{ kind: "audio"; frame: Int16Array }>
  | Readonly<{ kind: "end" }>

// Only finite preroll is retained. Continuous speech is split without repeating captured samples.
export class SpeechSegmenter {
  private readonly settings: Readonly<{ prerollMs: number; silenceMs: number; softTurnMs: number; hardTurnMs: number; threshold: number }>
  private preroll: Int16Array[] = []
  private prerollSamples = 0
  private active = false
  private turnSamples = 0
  private silenceSamples = 0
  private closed = false

  constructor(readonly sampleRate: number, settings = {
    prerollMs: 300, silenceMs: 550, softTurnMs: 6000, hardTurnMs: 10_000, threshold: 0.5,
  }) {
    if (![16_000, 24_000].includes(sampleRate) || !Object.values(settings).every(Number.isFinite)
      || settings.prerollMs < 0 || settings.prerollMs > 300 || settings.silenceMs <= 0
      || settings.softTurnMs <= 0 || settings.hardTurnMs <= 0 || settings.hardTurnMs > 10_000
      || settings.softTurnMs > settings.hardTurnMs || settings.silenceMs > settings.hardTurnMs
      || settings.threshold < 0 || settings.threshold > 1) throw new TranscriptionError("audio")
    this.settings = Object.freeze({ ...settings })
  }

  accept(frame: Int16Array, probability: number): readonly SpeechAction[] {
    if (this.closed) throw new TranscriptionError("stopped")
    if (!(frame instanceof Int16Array) || frame.length === 0 || frame.length > this.sampleRate / 10 || !Number.isFinite(probability)
      || probability < 0 || probability > 1) throw new TranscriptionError("audio")
    const speech = probability >= this.settings.threshold
    const actions: SpeechAction[] = []
    if (!this.active) {
      this.preroll.push(frame.slice())
      this.prerollSamples += frame.length
      while (this.preroll.length > 1 && this.prerollSamples > this.sampleRate * this.settings.prerollMs / 1000) {
        this.prerollSamples -= this.preroll.shift()!.length
      }
      if (!speech) return []
      this.active = true
      this.turnSamples = this.prerollSamples
      this.silenceSamples = 0
      actions.push({ kind: "start", frames: this.preroll })
      this.preroll = []
      this.prerollSamples = 0
    } else {
      this.turnSamples += frame.length
      this.silenceSamples = speech ? 0 : this.silenceSamples + frame.length
      actions.push({ kind: "audio", frame })
    }
    const silenceBoundary = this.silenceSamples >= this.sampleRate * this.settings.silenceMs / 1000
      || (this.turnSamples >= this.sampleRate * this.settings.softTurnMs / 1000
        && this.silenceSamples >= this.sampleRate * 0.2)
    if (silenceBoundary || this.turnSamples >= this.sampleRate * this.settings.hardTurnMs / 1000) {
      this.active = false
      this.turnSamples = 0
      this.silenceSamples = 0
      actions.push({ kind: "end" })
    }
    return actions
  }

  stop(): boolean {
    if (this.closed) return false
    this.closed = true
    this.preroll = []
    this.prerollSamples = 0
    const unfinished = this.active
    this.active = false
    return unfinished
  }
}
