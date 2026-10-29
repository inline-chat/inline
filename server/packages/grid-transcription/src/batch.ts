import { TranscriptionError, type Model } from "./protocol.js"

export type BatchTranscriber = (model: Model, apiKey: string, samples: Int16Array, sampleRate: number) => Promise<string>
export type BatchOptions = Readonly<{ fetch?: typeof fetch; pollMs?: number; deadlineMs?: number }>

const SONIOX_API = "https://api.soniox.com/v1"
const SONIOX_ASYNC_MODEL = "stt-async-v5"
const OPENAI_TRANSCRIPTIONS = "https://api.openai.com/v1/audio/transcriptions"
const OPENAI_BATCH_MODEL = "gpt-transcribe"

/** Transcribes one spooled turn through the provider's file API. Never logs audio or text. */
export function batchTranscriber(options: BatchOptions = {}): BatchTranscriber {
  const request = options.fetch ?? fetch
  const pollMs = options.pollMs ?? 1_000
  const deadlineMs = options.deadlineMs ?? 5 * 60 * 1000
  return async (model, apiKey, samples, sampleRate) => {
    if (samples.length === 0) return ""
    // Bound the whole request, including upload and response bodies, rather than only
    // checking the deadline between completed status polls.
    const signal = AbortSignal.timeout(deadlineMs)
    const boundedRequest: typeof fetch = (input, init) => request(input, { ...init, signal })
    const audio = new Blob([wav(samples, sampleRate)], { type: "audio/wav" })
    if (model === "standard") {
      const form = new FormData()
      form.append("model", OPENAI_BATCH_MODEL)
      form.append("file", audio, "turn.wav")
      const body = await json(await boundedRequest(OPENAI_TRANSCRIPTIONS, {
        method: "POST", headers: { Authorization: `Bearer ${apiKey}` }, body: form,
      }))
      return typeof body.text === "string" ? body.text.trim() : ""
    }
    const headers = { Authorization: `Bearer ${apiKey}` }
    const form = new FormData()
    form.append("file", audio, "turn.wav")
    const file = await json(await boundedRequest(`${SONIOX_API}/files`, { method: "POST", headers, body: form }))
    const fileId = stringField(file, "id")
    let transcriptionId: string | undefined
    try {
      const created = await json(await boundedRequest(`${SONIOX_API}/transcriptions`, {
        method: "POST", headers: { ...headers, "Content-Type": "application/json" },
        body: JSON.stringify({ model: SONIOX_ASYNC_MODEL, file_id: fileId }),
      }))
      transcriptionId = stringField(created, "id")
      for (const started = Date.now(); ;) {
        const status = await json(await boundedRequest(`${SONIOX_API}/transcriptions/${transcriptionId}`, { headers }))
        if (status.status === "completed") break
        if (status.status === "error") throw new TranscriptionError("provider")
        if (Date.now() - started > deadlineMs) throw new TranscriptionError("provider")
        await new Promise((resolve) => setTimeout(resolve, pollMs))
      }
      const transcript = await json(await boundedRequest(`${SONIOX_API}/transcriptions/${transcriptionId}/transcript`, { headers }))
      const tokens = Array.isArray(transcript.tokens) ? transcript.tokens : []
      return tokens.map((token: unknown) =>
        token && typeof token === "object" && typeof (token as { text?: unknown }).text === "string"
          ? (token as { text: string }).text : "").join("").trim()
    } finally {
      // Cleanup gets its own short deadline even when transcription timed out.
      const cleanupSignal = AbortSignal.timeout(10_000)
      if (transcriptionId) await request(`${SONIOX_API}/transcriptions/${transcriptionId}`, { method: "DELETE", headers, signal: cleanupSignal }).catch(() => undefined)
      await request(`${SONIOX_API}/files/${fileId}`, { method: "DELETE", headers, signal: cleanupSignal }).catch(() => undefined)
    }
  }
}

/** 16-bit mono PCM in a canonical 44-byte RIFF/WAVE container. */
export function wav(samples: Int16Array, sampleRate: number): Uint8Array<ArrayBuffer> {
  const data = Buffer.from(samples.buffer, samples.byteOffset, samples.byteLength)
  const header = Buffer.alloc(44)
  header.write("RIFF", 0)
  header.writeUInt32LE(36 + data.length, 4)
  header.write("WAVE", 8)
  header.write("fmt ", 12)
  header.writeUInt32LE(16, 16)
  header.writeUInt16LE(1, 20)
  header.writeUInt16LE(1, 22)
  header.writeUInt32LE(sampleRate, 24)
  header.writeUInt32LE(sampleRate * 2, 28)
  header.writeUInt16LE(2, 32)
  header.writeUInt16LE(16, 34)
  header.write("data", 36)
  header.writeUInt32LE(data.length, 40)
  const file = new Uint8Array(header.length + data.length)
  file.set(header)
  file.set(data, header.length)
  return file
}

async function json(response: Response): Promise<Record<string, unknown>> {
  if (!response.ok) throw new TranscriptionError("provider")
  const value: unknown = await response.json()
  if (!value || typeof value !== "object") throw new TranscriptionError("protocol")
  return value as Record<string, unknown>
}
function stringField(value: Record<string, unknown>, key: string): string {
  const field = value[key]
  if (typeof field !== "string" || !field || field.length > 256 || !/^[\w-]+$/.test(field)) throw new TranscriptionError("protocol")
  return field
}
