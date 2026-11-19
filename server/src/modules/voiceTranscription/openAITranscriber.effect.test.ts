import { afterEach, beforeEach, expect, test, vi } from "vitest"
import type { DbFullVoice } from "@in/server/db/models/files"
import {
  maxConcurrentVoiceTranscriptions,
  transcribeAudioFileWithOpenAI,
  transcribeVoiceWithOpenAI,
} from "./openAITranscriber"

const mocks = vi.hoisted(() => ({ create: vi.fn(), signedUrl: vi.fn() }))
vi.mock("@in/server/libs/openAI", () => ({ openaiClient: { audio: { transcriptions: { create: mocks.create } } } }))
vi.mock("@in/server/modules/files/path", () => ({ getSignedUrl: mocks.signedUrl }))

beforeEach(() => {
  mocks.create.mockReset()
  mocks.create.mockResolvedValue({ text: "  hello  " })
  mocks.signedUrl.mockReturnValue("https://files.example.test/voice.m4a")
  vi.stubGlobal("fetch", vi.fn(async () => new Response(new Uint8Array([1, 2]))))
})
afterEach(() => { vi.unstubAllGlobals() })
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

const voice = (id: number, duration: number | null = 5) =>
  ({ id, fileId: id, duration, file: { path: "voice.m4a", mimeType: "audio/mp4", fileSize: 2 } }) as unknown as DbFullVoice

test("stored voice messages get one bounded attempt and a single retry", async () => {
  expect(await transcribeVoiceWithOpenAI(voice(1))).toBe("hello")
  expect(mocks.create).toHaveBeenCalledWith(
    expect.objectContaining({ model: "gpt-transcribe" }),
    { timeout: 60_000, maxRetries: 1 },
  )
})

test("voice messages over the duration cap are not downloaded or sent", async () => {
  expect(await transcribeVoiceWithOpenAI(voice(2, 601))).toBeUndefined()
  expect(fetch).not.toHaveBeenCalled()
  expect(mocks.create).not.toHaveBeenCalled()
  expect(await transcribeVoiceWithOpenAI(voice(3, null))).toBe("hello")
})

test("at most four stored voice messages are transcribed at once", async () => {
  const releases: Array<() => void> = []
  mocks.create.mockImplementation(
    () => new Promise((resolve) => releases.push(() => resolve({ text: "done" }))),
  )
  const runs = Array.from({ length: maxConcurrentVoiceTranscriptions + 2 }, (_, index) =>
    transcribeVoiceWithOpenAI(voice(10 + index)),
  )
  await vi.waitFor(() => expect(mocks.create).toHaveBeenCalledTimes(maxConcurrentVoiceTranscriptions))
  await new Promise((resolve) => setTimeout(resolve, 10))
  expect(mocks.create).toHaveBeenCalledTimes(maxConcurrentVoiceTranscriptions)

  releases.shift()?.()
  await vi.waitFor(() => expect(mocks.create).toHaveBeenCalledTimes(maxConcurrentVoiceTranscriptions + 1))
  while (releases.length > 0 || mocks.create.mock.calls.length < runs.length) {
    releases.shift()?.()
    await new Promise((resolve) => setTimeout(resolve, 1))
  }
  expect(await Promise.all(runs)).toEqual(Array.from({ length: runs.length }, () => "done"))
})
