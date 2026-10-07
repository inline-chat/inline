import { TranscriptionError } from "./protocol.js"

export function pcm16le(samples: Int16Array): Uint8Array {
  if (samples.length === 0 || samples.length > 48_000) throw new TranscriptionError("audio")
  const bytes = new Uint8Array(samples.byteLength)
  const view = new DataView(bytes.buffer)
  for (let i = 0; i < samples.length; i++) view.setInt16(i * 2, samples[i]!, true)
  return bytes
}

// Read native frames promptly into this queue. Provider I/O belongs to a separate consumer.
export class BoundedPcmQueue {
  private frames: Int16Array[] = []
  private queuedSamples = 0
  private waiter: { resolve: (frame: Int16Array | undefined) => void; reject: (error: Error) => void } | undefined
  private closed = false
  private failure: Error | undefined

  constructor(readonly maxSamples: number) {
    if (!Number.isSafeInteger(maxSamples) || maxSamples <= 0 || maxSamples > 48_000 * 10) {
      throw new TranscriptionError("audio")
    }
  }

  push(frame: Int16Array): void {
    if (this.closed) throw this.failure ?? new TranscriptionError("stopped")
    if (frame.length === 0 || frame.length > this.maxSamples) {
      const error = new TranscriptionError("overflow")
      this.close(error)
      throw error
    }
    if (this.queuedSamples + frame.length > this.maxSamples) {
      const error = new TranscriptionError("overflow")
      this.close(error)
      throw error
    }
    const owned = frame.slice()
    if (this.waiter) {
      const waiter = this.waiter
      this.waiter = undefined
      waiter.resolve(owned)
    } else {
      this.frames.push(owned)
      this.queuedSamples += owned.length
    }
  }

  take(): Promise<Int16Array | undefined> {
    if (this.failure) return Promise.reject(this.failure)
    const frame = this.frames.shift()
    if (frame) {
      this.queuedSamples -= frame.length
      return Promise.resolve(frame)
    }
    if (this.closed) return Promise.resolve(undefined)
    if (this.waiter) return Promise.reject(new TranscriptionError("protocol"))
    return new Promise((resolve, reject) => { this.waiter = { resolve, reject } })
  }

  // Stop discards unsent audio; accepted provider speech is flushed by its own bounded owner.
  close(failure?: Error): void {
    if (this.closed) return
    this.closed = true
    this.failure = failure
    this.frames = []
    this.queuedSamples = 0
    const waiter = this.waiter
    this.waiter = undefined
    if (failure) waiter?.reject(failure)
    else waiter?.resolve(undefined)
  }

  get bufferedSamples(): number { return this.queuedSamples }
}
