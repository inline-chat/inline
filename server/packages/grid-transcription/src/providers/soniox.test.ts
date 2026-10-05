import { describe, expect, test } from "bun:test"
import { MAX_PENDING_TURNS, MAX_TURN_TEXT_BYTES, TranscriptionError } from "../protocol.js"
import {
  SONIOX_MAX_SOCKET_TURNS,
  SonioxTurnDecoder,
  sonioxAudio,
  sonioxConfiguration,
  sonioxFinalize,
  sonioxKeepalive,
} from "./soniox.js"

// Public token contract: https://soniox.com/docs/stt/rt/real-time-transcription
const token = (text: string, is_final = true) => ({ text, is_final })
const response = (...tokens: Readonly<{ text: string; is_final: boolean }>[]) => ({ tokens })

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

describe("Soniox manually finalized wire", () => {
  test("uses automatic languages, raw PCM16k and application boundaries", () => {
    expect(sonioxConfiguration("test-key")).toEqual({
      api_key: "test-key",
      model: "stt-rt-v5",
      audio_format: "pcm_s16le",
      sample_rate: 16_000,
      num_channels: 1,
      enable_speaker_diarization: false,
      enable_endpoint_detection: false,
    })
    expect(sonioxFinalize()).toEqual({ type: "finalize" })
    expect(sonioxKeepalive()).toEqual({ type: "keepalive" })
    const pcm = Uint8Array.of(0, 128, 255, 127)
    const sent = sonioxAudio(pcm)
    pcm.fill(0)
    expect(sent).toEqual(Uint8Array.of(0, 128, 255, 127))
    expectFailure(() => sonioxAudio(Uint8Array.of(1)), "audio")
    expectFailure(() => sonioxAudio(new Uint8Array()), "audio")
    expectFailure(() => sonioxAudio(new Uint8Array(65_538)), "audio")
  })

  test("ignores revised provisional text and emits stable tokens only on the manual marker", () => {
    const decoder = new SonioxTurnDecoder()
    expect(decoder.accept(response(token("How're", false)))).toEqual([])
    expect(decoder.accept(response(token("How", false), token(" are", false)))).toEqual([])
    // The provider may finalize tokens before the application sends its manual finalize command.
    expect(decoder.accept(response(token("How"), token(" are", false)))).toEqual([])
    decoder.beginTurn("local_1")
    expect(decoder.accept(response(token(" are"), token(" you", false)))).toEqual([])
    expect(decoder.accept(response(token(" you"), token(" doing?"), token("<fin>")))).toEqual([
      { turnId: "local_1", text: "How are you doing?" },
    ])
  })

  test("multiple finalization markers partition one event in admitted FIFO order", () => {
    const decoder = new SonioxTurnDecoder()
    decoder.beginTurn("one")
    decoder.beginTurn("two")
    expect(decoder.accept(response(
      token("first"), token("<fin>"), token("دوم"), token("<fin>"),
    ))).toEqual([
      { turnId: "one", text: "first" },
      { turnId: "two", text: "دوم" },
    ])
    expectFailure(() => decoder.beginTurn("one"), "protocol")
  })

  test("rejects unsolicited markers and semantic endpoints that contradict manual configuration", () => {
    for (const marker of ["<fin>", "<end>"]) {
      const decoder = new SonioxTurnDecoder()
      expectFailure(() => decoder.accept(response(token(marker))), "protocol")
      expectFailure(() => decoder.beginTurn("later"), "stopped")
    }
  })

  test("safe provider failures expose no error detail or buffered transcript", () => {
    const decoder = new SonioxTurnDecoder()
    decoder.accept(response(token("private transcript")))
    expectFailure(() => decoder.accept({
      tokens: [], error_code: 503, error_type: "service_unavailable", error_message: "SECRET detail",
    }), "provider")
    expectFailure(() => decoder.accept(response(token("<fin>"))), "stopped")
  })

  test("validates malformed input and discards all state on failure", () => {
    for (const event of [
      null, [], {}, { tokens: "text" }, { tokens: [null] },
      { tokens: [{ text: "text", is_final: 1 }] }, { tokens: [{ text: 42, is_final: true }] },
      { tokens: [], finished: "true" },
    ]) {
      const decoder = new SonioxTurnDecoder()
      expectFailure(() => decoder.accept(event), "protocol")
      expectFailure(() => decoder.accept(response()), "stopped")
    }
  })

  test("bounds pending turns, cumulative UTF8 text, token arrays and socket ID retention", () => {
    const pending = new SonioxTurnDecoder()
    for (let index = 0; index < MAX_PENDING_TURNS; index++) pending.beginTurn(`turn_${index}`)
    expectFailure(() => pending.beginTurn("overflow"), "overflow")
    const text = new SonioxTurnDecoder()
    text.accept(response(token("a".repeat(MAX_TURN_TEXT_BYTES - 2))))
    expectFailure(() => text.accept(response(token("界"))), "overflow")
    const tokens = new SonioxTurnDecoder()
    expectFailure(() => tokens.accept({ tokens: Array.from({ length: MAX_TURN_TEXT_BYTES + 1 }, () => token("")) }), "overflow")
    const history = new SonioxTurnDecoder()
    for (let index = 0; index < SONIOX_MAX_SOCKET_TURNS; index++) {
      history.beginTurn(`local_${index}`)
      history.accept(response(token("text"), token("<fin>")))
    }
    expectFailure(() => history.beginTurn("history_overflow"), "overflow")
  })

  test("emits empty terminal turns and accepts clean end-of-stream only after the final flush", () => {
    const decoder = new SonioxTurnDecoder()
    decoder.beginTurn("silence")
    expect(decoder.accept(response(token(" \n"), token("<fin>")))).toEqual([{ turnId: "silence", text: "" }])
    expect(decoder.accept({ tokens: [], final_audio_proc_ms: 1560, total_audio_proc_ms: 1680, finished: true })).toEqual([])
    expectFailure(() => decoder.accept(response(token("late"))), "stopped")
    const pending = new SonioxTurnDecoder()
    pending.beginTurn("missing_flush")
    expectFailure(() => pending.accept({ tokens: [], finished: true }), "protocol")
  })

  test("explicit close is idempotent and fences delayed provider output", () => {
    const decoder = new SonioxTurnDecoder()
    decoder.accept(response(token("buffered")))
    decoder.close()
    decoder.close()
    expectFailure(() => decoder.beginTurn("late"), "stopped")
    expectFailure(() => decoder.accept(response(token("<fin>"))), "stopped")
  })
})
