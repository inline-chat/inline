import { beforeEach, expect, test, vi } from "vitest"
import { transcribeAudioFileWithOpenAI } from "./openAITranscriber"

const mocks = vi.hoisted(() => ({ create: vi.fn() }))
vi.mock("@in/server/libs/openAI", () => ({ openaiClient: { audio: { transcriptions: { create: mocks.create } } } }))
vi.mock("@in/server/modules/files/path", () => ({ getSignedUrl: vi.fn() }))

beforeEach(() => { mocks.create.mockResolvedValue({ text: "  hello  " }) })
const file = () => new File([new Uint8Array([1, 2])], "dictation.m4a", { type: "audio/mp4" })

test("dictation uses GPT and forwards its cancellation deadline without provider retries", async () => {
  const signal = new AbortController().signal
  const audio = file()
  expect(await transcribeAudioFileWithOpenAI(audio, { signal })).toBe("hello")
  expect(mocks.create).toHaveBeenCalledWith(
    expect.objectContaining({ model: "gpt-transcribe", file: audio, response_format: "json" }),
    { signal, maxRetries: 0 },
  )
})

test("ordinary voice transcription keeps the existing provider request options", async () => {
  await transcribeAudioFileWithOpenAI(file(), { languages: ["fa"] })
  expect(mocks.create).toHaveBeenCalledWith(expect.objectContaining({ languages: ["fa"] }), undefined)
})

test("empty speech does not become text", async () => {
  mocks.create.mockResolvedValueOnce({ text: "  " })
  expect(await transcribeAudioFileWithOpenAI(file())).toBeUndefined()
})

test("provider failure propagates to the handler's public error boundary", async () => {
  mocks.create.mockRejectedValueOnce(new Error("provider unavailable"))
  await expect(transcribeAudioFileWithOpenAI(file())).rejects.toThrow("provider unavailable")
})
