import { describe, expect, test } from "bun:test"
import { batchTranscriber, wav } from "./batch.js"

type Call = { method: string; url: string; body?: unknown }
function provider(responses: Record<string, unknown[]>) {
  const calls: Call[] = []
  const fetcher = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input)
    const method = init?.method ?? "GET"
    calls.push({ method, url, body: init?.body })
    const key = `${method} ${url.replace(/^https:\/\/[^/]+/, "")}`
    const queue = responses[key]
    const next = queue?.length ? queue.shift() : {}
    if (next instanceof Response) return next
    return new Response(JSON.stringify(next), { status: 200 })
  }) as typeof fetch
  return { calls, fetcher }
}

describe("batch transcription", () => {
  test("wraps PCM in a canonical mono 16-bit WAV header", () => {
    const file = Buffer.from(wav(new Int16Array([1, -1]), 16_000))
    expect(file.subarray(0, 4).toString()).toBe("RIFF")
    expect(file.readUInt32LE(24)).toBe(16_000)
    expect(file.readUInt16LE(22)).toBe(1)
    expect(file.readUInt32LE(40)).toBe(4)
    expect(file.length).toBe(48)
  })

  test("Soniox uploads, polls, joins tokens and always deletes provider copies", async () => {
    const { calls, fetcher } = provider({
      "POST /v1/files": [{ id: "file-1" }],
      "POST /v1/transcriptions": [{ id: "tr-1" }],
      "GET /v1/transcriptions/tr-1": [{ status: "processing" }, { status: "completed" }],
      "GET /v1/transcriptions/tr-1/transcript": [{ tokens: [{ text: "Hello" }, { text: " there." }] }],
    })
    const text = await batchTranscriber({ fetch: fetcher, pollMs: 1 })("meeting", "key", new Int16Array(160), 16_000)
    expect(text).toBe("Hello there.")
    expect(calls.find((call) => call.url.endsWith("/v1/transcriptions") && call.method === "POST")?.body)
      .toBe(JSON.stringify({ model: "stt-async-v5", file_id: "file-1" }))
    expect(calls.filter((call) => call.method === "DELETE").map((call) => call.url.split("/v1/")[1]).sort())
      .toEqual(["files/file-1", "transcriptions/tr-1"])
  })

  test("a Soniox job error still deletes the uploaded file and rejects for retry", async () => {
    const { calls, fetcher } = provider({
      "POST /v1/files": [{ id: "file-2" }],
      "POST /v1/transcriptions": [{ id: "tr-2" }],
      "GET /v1/transcriptions/tr-2": [{ status: "error" }],
    })
    await expect(batchTranscriber({ fetch: fetcher, pollMs: 1 })("meeting", "key", new Int16Array(160), 16_000)).rejects.toThrow("provider")
    expect(calls.filter((call) => call.method === "DELETE")).toHaveLength(2)
  })

  test("OpenAI transcribes the file in one request and empty audio skips the provider", async () => {
    const { calls, fetcher } = provider({ "POST /v1/audio/transcriptions": [{ text: " Standard line. " }] })
    const transcribe = batchTranscriber({ fetch: fetcher })
    expect(await transcribe("standard", "key", new Int16Array(240), 24_000)).toBe("Standard line.")
    expect(await transcribe("meeting", "key", new Int16Array(0), 16_000)).toBe("")
    expect(calls).toHaveLength(1)
  })

  test("a provider HTTP error rejects so recovery keeps the audio", async () => {
    const { fetcher } = provider({ "POST /v1/files": [new Response("{}", { status: 503 })] })
    await expect(batchTranscriber({ fetch: fetcher })("meeting", "key", new Int16Array(160), 16_000)).rejects.toThrow("provider")
  })
})
