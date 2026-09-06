import { beforeEach, describe, expect, test, vi } from "vitest"
import { RpcCall, RpcResult, Method } from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { transcribeVoiceDraft } from "./voice.transcribeDraft"

const mocks = vi.hoisted(() => ({ transcribe: vi.fn() }))
vi.mock("@in/server/modules/voiceTranscription/openAITranscriber", () => ({ transcribeAudioFileWithOpenAI: mocks.transcribe }))

let userId = 100
let context: HandlerContext
const input = () => ({ audio: new Uint8Array([1, 2, 3]), mimeType: "audio/mp4", duration: 5 })
beforeEach(() => {
  context = { userId: ++userId, sessionId: 1, connectionId: "dictation-test", sendRaw() {}, sendRpcReply() {} }
  mocks.transcribe.mockResolvedValue("  hello from dictation  ")
})

describe("draft voice transcription", () => {
  test("passes transient audio to GPT and returns trimmed text", async () => {
    expect(await transcribeVoiceDraft(input(), context)).toEqual({ text: "hello from dictation" })
    expect(mocks.transcribe).toHaveBeenCalledTimes(1)
    const [file, options] = mocks.transcribe.mock.calls[0]!
    expect(file.name).toBe("dictation.m4a")
    expect(file.type).toBe("audio/mp4")
    expect(new Uint8Array(await file.arrayBuffer())).toEqual(input().audio)
    expect(options.signal).toBeInstanceOf(AbortSignal)
  })
  test("requires authentication before invoking GPT", async () => {
    await expect(transcribeVoiceDraft(input(), { ...context, userId: 0 })).rejects.toThrow()
    expect(mocks.transcribe).not.toHaveBeenCalled()
  })
  test.each([0, 4 * 1024 * 1024 + 1])("rejects invalid audio size %s", async (size) => {
    await expect(transcribeVoiceDraft({ ...input(), audio: new Uint8Array(size) }, context)).rejects.toThrow("cannot be transcribed")
    expect(mocks.transcribe).not.toHaveBeenCalled()
  })
  test.each([0, 601])("rejects invalid duration %s", async (duration) => {
    await expect(transcribeVoiceDraft({ ...input(), duration }, context)).rejects.toThrow("cannot be transcribed")
    expect(mocks.transcribe).not.toHaveBeenCalled()
  })
  test.each(["", "application/octet-stream", "text/plain"])("rejects unsupported MIME type %s", async (mimeType) => {
    await expect(transcribeVoiceDraft({ ...input(), mimeType }, context)).rejects.toThrow("cannot be transcribed")
    expect(mocks.transcribe).not.toHaveBeenCalled()
  })
  test.each(["audio/mp4", "audio/x-m4a", "audio/ogg"])("accepts supported MIME type %s", async (mimeType) => {
    await transcribeVoiceDraft({ ...input(), mimeType }, context)
    expect(mocks.transcribe).toHaveBeenCalledTimes(1)
  })
  test.each([undefined, "", "  "])("empty result %s never becomes a sendable transcript", async (text) => {
    mocks.transcribe.mockResolvedValueOnce(text)
    await expect(transcribeVoiceDraft(input(), context)).rejects.toThrow("No transcript")
  })
  test("sanitizes provider failures", async () => {
    mocks.transcribe.mockRejectedValueOnce(new Error("private provider request details"))
    await expect(transcribeVoiceDraft(input(), context)).rejects.toThrow("Could not transcribe this recording. Please try again.")
  })
  test("an expired application request never reaches GPT", async () => {
    const controller = new AbortController()
    controller.abort()
    await expect(transcribeVoiceDraft(input(), { ...context, signal: controller.signal })).rejects.toThrow("Transcription took too long")
    expect(mocks.transcribe).not.toHaveBeenCalled()
  })
  test("limits repeated requests before invoking GPT", async () => {
    for (let i = 0; i < 6; i++) await transcribeVoiceDraft(input(), context)
    await expect(transcribeVoiceDraft(input(), context)).rejects.toThrow()
    expect(mocks.transcribe).toHaveBeenCalledTimes(6)
  })
  test("preserves dictated Persian text", async () => {
    mocks.transcribe.mockResolvedValueOnce("  سلام دنیا  ")
    expect(await transcribeVoiceDraft(input(), context)).toEqual({ text: "سلام دنیا" })
  })
  test("round trips the new request and result wire fields", () => {
    const call = RpcCall.create({ method: Method.TRANSCRIBE_VOICE_DRAFT, input: { oneofKind: "transcribeVoiceDraft", transcribeVoiceDraft: input() } })
    expect(RpcCall.fromBinary(RpcCall.toBinary(call))).toEqual(call)
    const result = RpcResult.create({ result: { oneofKind: "transcribeVoiceDraft", transcribeVoiceDraft: { text: "سلام" } } })
    expect(RpcResult.fromBinary(RpcResult.toBinary(result))).toEqual(result)
  })
})
