import { Buffer } from "node:buffer"
import { describe, expect, test } from "bun:test"
import { MAX_PENDING_TURNS, MAX_TURN_TEXT_BYTES, TranscriptionError } from "../protocol.js"
import {
  OPENAI_MAX_SOCKET_TURNS,
  OpenAITurnDecoder,
  openAIAppendAudio,
  openAICommit,
  openAIConfiguration,
  openAIConfigurationAccepted,
} from "./openai.js"

// Public event shapes: https://developers.openai.com/api/reference/resources/realtime/server-events
const committed = (itemId: string, previousItemId: string | null = null) => ({
  type: "input_audio_buffer.committed",
  event_id: `ack_${itemId}`,
  item_id: itemId,
  previous_item_id: previousItemId,
})
const completed = (itemId: string, transcript: string) => ({
  type: "conversation.item.input_audio_transcription.completed",
  event_id: `final_${itemId}`,
  item_id: itemId,
  content_index: 0,
  transcript,
  usage: { type: "duration", seconds: 1.6 },
})

function expectFailure(action: () => unknown, code: TranscriptionError["code"]) {
  let caught: unknown
  try {
    action()
  } catch (error) {
    caught = error
  }
  expect(caught).toBeInstanceOf(TranscriptionError)
  if (!(caught instanceof TranscriptionError)) throw new Error("Expected safe transcription failure")
  expect(caught.code).toBe(code)
  expect(caught.message).toBe(`Grid transcription ${code}`)
}

describe("OpenAI committed-turn wire", () => {
  test("uses dedicated transcription, manual commits, automatic languages and PCM24k", () => {
    expect(openAIConfiguration()).toEqual({
      type: "session.update",
      session: {
        type: "transcription",
        audio: {
          input: {
            format: { type: "audio/pcm", rate: 24_000 },
            transcription: { model: "gpt-transcribe" },
            turn_detection: null,
          },
        },
      },
    })
    const pcm = Uint8Array.of(0, 128, 255, 127)
    const append = openAIAppendAudio(pcm)
    expect(append.type).toBe("input_audio_buffer.append")
    expect(Buffer.from(append.audio, "base64")).toEqual(Buffer.from(pcm))
    expect(openAICommit()).toEqual({ type: "input_audio_buffer.commit" })
    expectFailure(() => openAIAppendAudio(Uint8Array.of(1)), "audio")
    expectFailure(() => openAIAppendAudio(new Uint8Array()), "audio")
    expectFailure(() => openAIAppendAudio(new Uint8Array(65_538)), "audio")
  })

  test("requires the matching effective configuration before accepting session readiness", () => {
    const requested = openAIConfiguration().session
    const echo = { type: "session.updated", session: { ...requested, id: "sess_public_fixture" } }
    expect(openAIConfigurationAccepted(echo)).toBe(true)
    expect(openAIConfigurationAccepted({ type: "session.created", session: requested })).toBe(false)
    const input = requested.audio.input
    const invalidSessions = [
      { ...requested, type: "realtime" },
      { ...requested, audio: { input: { ...input, format: { type: "audio/pcmu", rate: 24_000 } } } },
      { ...requested, audio: { input: { ...input, format: { type: "audio/pcm", rate: 16_000 } } } },
      { ...requested, audio: { input: { ...input, transcription: { model: "gpt-live-transcribe" } } } },
      { ...requested, audio: { input: { ...input, turn_detection: { type: "server_vad" } } } },
      { ...requested, audio: { input: { ...input, turn_detection: undefined } } },
      { ...requested, audio: {} },
      { ...requested, audio: { input: { ...input, transcription: null } } },
    ]
    for (const session of invalidSessions) {
      expectFailure(() => openAIConfigurationAccepted({ type: "session.updated", session }), "protocol")
    }
    expectFailure(() => openAIConfigurationAccepted({ type: "session.updated" }), "protocol")
  })

  test("ignores partial text and preserves local order when provider finals arrive out of order", () => {
    const decoder = new OpenAITurnDecoder()
    decoder.beginTurn("local_1")
    decoder.beginTurn("local_2")
    expect(decoder.accept(committed("item_1"))).toEqual([])
    expect(decoder.accept(committed("item_2", "item_1"))).toEqual([])
    expect(decoder.accept({
      type: "conversation.item.input_audio_transcription.delta",
      item_id: "item_1",
      content_index: 0,
      delta: "wrong provisional text",
    })).toEqual([])
    expect(decoder.accept(completed("item_2", "second"))).toEqual([])
    expect(decoder.accept(completed("item_1", "first"))).toEqual([
      { turnId: "local_1", text: "first" },
      { turnId: "local_2", text: "second" },
    ])
    decoder.beginTurn("local_3")
    expect(decoder.accept(completed("item_1", "stale duplicate"))).toEqual([])
    expect(decoder.accept(committed("item_2", "item_1"))).toEqual([])
    expect(decoder.accept(committed("item_3", "item_2"))).toEqual([])
    expect(decoder.accept(completed("item_3", "third"))).toEqual([{ turnId: "local_3", text: "third" }])
  })

  test("buffers a final that precedes its commit acknowledgement without guessing identity", () => {
    const decoder = new OpenAITurnDecoder()
    decoder.beginTurn("first")
    decoder.beginTurn("second")
    expect(decoder.accept(completed("item_2", "second text"))).toEqual([])
    expect(decoder.accept(completed("item_1", "first text"))).toEqual([])
    expect(decoder.accept(committed("item_1"))).toEqual([{ turnId: "first", text: "first text" }])
    expect(decoder.accept(committed("item_2", "item_1"))).toEqual([{ turnId: "second", text: "second text" }])
  })

  test("does not revise a final blocked behind another turn", () => {
    const decoder = new OpenAITurnDecoder()
    decoder.beginTurn("first")
    decoder.beginTurn("second")
    decoder.accept(committed("item_1"))
    decoder.accept(committed("item_2", "item_1"))
    decoder.accept(completed("item_2", "original"))
    decoder.accept(completed("item_2", "repeated or stale"))
    expect(decoder.accept(completed("item_1", "first"))).toEqual([
      { turnId: "first", text: "first" },
      { turnId: "second", text: "original" },
    ])
  })

  test("accepts optional predecessors but rejects a conflicting acknowledged chain", () => {
    const decoder = new OpenAITurnDecoder()
    decoder.beginTurn("one")
    expect(decoder.accept({ type: "input_audio_buffer.committed", item_id: "one" })).toEqual([])
    decoder.beginTurn("two")
    expectFailure(() => decoder.accept(committed("two", "unknown")), "protocol")
    expectFailure(() => decoder.accept(completed("one", "late")), "stopped")
  })

  test("safe provider errors stop decoding without leaking raw error text", () => {
    for (const event of [
      { type: "error", error: { message: "SECRET audio and provider detail" } },
      { type: "conversation.item.input_audio_transcription.failed", error: { message: "SECRET" } },
    ]) {
      const decoder = new OpenAITurnDecoder()
      decoder.beginTurn("turn")
      expectFailure(() => decoder.accept(event), "provider")
      expectFailure(() => decoder.beginTurn("next"), "stopped")
    }
  })

  test("rejects unadmitted/malformed finals and acknowledgement reordering", () => {
    for (const event of [null, [], { type: "unexpected" }, completed("unknown", "text")]) {
      const decoder = new OpenAITurnDecoder()
      expectFailure(() => decoder.accept(event), "protocol")
    }
    const decoder = new OpenAITurnDecoder()
    decoder.beginTurn("local")
    expectFailure(() => decoder.accept({ ...completed("item", "text"), content_index: 1 }), "protocol")
    const reordered = new OpenAITurnDecoder()
    reordered.beginTurn("first")
    reordered.beginTurn("second")
    expectFailure(() => reordered.accept(committed("item_2", "item_1")), "protocol")
  })

  test("bounds pending turns, early finals, UTF8 text and duplicate history without eviction", () => {
    const pending = new OpenAITurnDecoder()
    for (let index = 0; index < MAX_PENDING_TURNS; index++) pending.beginTurn(`turn_${index}`)
    expectFailure(() => pending.beginTurn("overflow"), "overflow")
    const early = new OpenAITurnDecoder()
    early.beginTurn("only")
    early.accept(completed("item_a", "first"))
    expectFailure(() => early.accept(completed("item_b", "second")), "overflow")
    const text = new OpenAITurnDecoder()
    text.beginTurn("text")
    expectFailure(() => text.accept(completed("text", "界".repeat(Math.ceil(MAX_TURN_TEXT_BYTES / 3)))), "overflow")
    const history = new OpenAITurnDecoder()
    for (let index = 0; index < OPENAI_MAX_SOCKET_TURNS; index++) {
      history.beginTurn(`local_${index}`)
      history.accept(committed(`item_${index}`, index === 0 ? null : `item_${index - 1}`))
      history.accept(completed(`item_${index}`, "text"))
    }
    expect(history.accept(completed("item_0", "old duplicate"))).toEqual([])
    expectFailure(() => history.beginTurn("history_overflow"), "overflow")
  })

  test("retires empty transcripts and close fences all later input", () => {
    const decoder = new OpenAITurnDecoder()
    decoder.beginTurn("silent")
    decoder.accept(committed("silent"))
    expect(decoder.accept(completed("silent", " \n"))).toEqual([{ turnId: "silent", text: "" }])
    expectFailure(() => decoder.beginTurn("silent"), "protocol")
    decoder.close()
    decoder.close()
    expectFailure(() => decoder.accept(completed("silent", "late")), "stopped")
  })
})
