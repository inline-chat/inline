import { describe, expect, test } from "bun:test"
import WebSocket, { WebSocketServer } from "ws"
import type { AddressInfo } from "node:net"
import { ProviderConnection, type SocketFactory } from "./socket.js"
import { openAIConfiguration } from "./providers/openai.js"
import { TranscriptionError, type FinalTurn } from "./protocol.js"

async function server() {
  const ws = new WebSocketServer({ host: "127.0.0.1", port: 0 })
  await new Promise<void>((resolve) => ws.once("listening", resolve))
  const endpoint = `ws://127.0.0.1:${(ws.address() as AddressInfo).port}`
  const factory: SocketFactory = (_url, headers) => new WebSocket(endpoint, { headers })
  const close = () => { for (const client of ws.clients) client.terminate(); ws.close() }
  return { ws, factory, close }
}

describe("provider wire qualification over actual local WebSockets", () => {
  test("Standard config, exact PCM, ack and final reach the local admitted turn", async () => {
    const fixture = await server()
    const packets: Record<string, unknown>[] = []
    let authorization: string | undefined
    let resolveTurn!: (turn: FinalTurn) => void
    const completed = new Promise<FinalTurn>((resolve) => { resolveTurn = resolve })
    fixture.ws.on("connection", (socket, request) => {
      authorization = request.headers.authorization
      socket.on("message", (data) => {
        const event = JSON.parse(data.toString()) as Record<string, unknown>
        packets.push(event)
        if (event.type === "session.update") socket.send(JSON.stringify({ type: "session.updated", session: openAIConfiguration().session }))
        if (event.type === "input_audio_buffer.commit") {
          socket.send(JSON.stringify({ type: "input_audio_buffer.committed", item_id: "item", previous_item_id: null }))
          socket.send(JSON.stringify({ type: "conversation.item.input_audio_transcription.delta", item_id: "item", delta: "wrong temporary" }))
          socket.send(JSON.stringify({ type: "conversation.item.input_audio_transcription.completed", item_id: "item", content_index: 0, transcript: "Ship it." }))
        }
      })
    })
    const failures: string[] = []
    let connection: ProviderConnection | undefined
    try {
      connection = await ProviderConnection.connect({ model: "standard", apiKey: "test-key", assertAuthority: () => {},
        onFinal: resolveTurn, onFailure: (error) => failures.push(error.code), socketFactory: fixture.factory })
      connection.appendAudio(new Int16Array([-1, 0x1234]))
      connection.commitTurn("admitted-turn")
      expect(await completed).toEqual({ turnId: "admitted-turn", text: "Ship it." })
      expect(authorization).toBe("Bearer test-key")
      const audio = packets.find((packet) => packet.type === "input_audio_buffer.append")?.audio
      expect([...Buffer.from(audio as string, "base64")]).toEqual([255, 255, 52, 18])
      expect(failures).toEqual([])
    } finally { connection?.close(); fixture.close() }
  })

  test("Meeting sends binary PCM and publishes final tokens only after its flush marker", async () => {
    const fixture = await server()
    const frames: Uint8Array[] = []
    let config: Record<string, unknown> | undefined
    let resolveTurn!: (turn: FinalTurn) => void
    const completed = new Promise<FinalTurn>((resolve) => { resolveTurn = resolve })
    fixture.ws.on("connection", (socket) => socket.on("message", (data, binary) => {
      if (binary) { frames.push(new Uint8Array(Buffer.from(data as Buffer))); return }
      const event = JSON.parse(data.toString()) as Record<string, unknown>
      if (event.model) config = event
      if (event.type === "finalize") {
        socket.send(JSON.stringify({ tokens: [{ text: "wrong temporary", is_final: false }] }))
        socket.send(JSON.stringify({ tokens: [{ text: "Ready.", is_final: true }, { text: "<fin>", is_final: true }] }))
      }
    }))
    let connection: ProviderConnection | undefined
    try {
      connection = await ProviderConnection.connect({ model: "meeting", apiKey: "test-key", assertAuthority: () => {},
        onFinal: resolveTurn, onFailure: () => {}, socketFactory: fixture.factory })
      expect(connection.sampleRate).toBe(16_000)
      connection.appendAudio(new Int16Array([-1, 0x1234]))
      connection.commitTurn("meeting-turn")
      expect(await completed).toEqual({ turnId: "meeting-turn", text: "Ready." })
      expect(config?.model).toBe("stt-rt-v5")
      expect(config?.enable_speaker_diarization).toBe(false)
      expect(config?.language_hints).toBeUndefined()
      expect([...frames[0]!]).toEqual([255, 255, 52, 18])
    } finally { connection?.close(); fixture.close() }
  })

  test("expired authority tears down the actual socket and rejects further writes", async () => {
    const fixture = await server()
    let expired = false
    let resolveClosed!: () => void
    const closed = new Promise<void>((resolve) => { resolveClosed = resolve })
    const failures: TranscriptionError[] = []
    fixture.ws.on("connection", (socket) => {
      socket.on("close", resolveClosed)
      socket.on("message", () => socket.send(JSON.stringify({ type: "session.updated", session: openAIConfiguration().session })))
    })
    let connection: ProviderConnection | undefined
    try {
      connection = await ProviderConnection.connect({ model: "standard", apiKey: "test-key",
        assertAuthority: () => { if (expired) throw new TranscriptionError("expired") },
        onFinal: () => {}, onFailure: (error) => failures.push(error), socketFactory: fixture.factory })
      expired = true
      expect(() => connection.appendAudio(new Int16Array([1]))).toThrow("expired")
      await closed
      expect(failures.map((error) => error.code)).toEqual(["expired"])
      expect(() => connection.commitTurn("late")).toThrow("expired")
    } finally { connection?.close(); fixture.close() }
  })

  test("provider error contents never enter surfaced error messages", async () => {
    const fixture = await server()
    fixture.ws.on("connection", (socket) => socket.on("message", () => socket.send(JSON.stringify({
      type: "error", error: { message: "private transcript or secret", code: "bad_key" },
    }))))
    const failures: TranscriptionError[] = []
    try {
      await expect(ProviderConnection.connect({ model: "standard", apiKey: "test-key", assertAuthority: () => {},
        onFinal: () => {}, onFailure: (error) => failures.push(error), socketFactory: fixture.factory })).rejects.toThrow("provider")
      expect(failures[0]?.message).toBe("Grid transcription provider")
    } finally { fixture.close() }
  })

  test("closing on the first turn prevents delivery of a later final in the same event", async () => {
    const fixture = await server()
    let commits = 0
    fixture.ws.on("connection", (socket) => socket.on("message", (data, binary) => {
      if (binary) return
      const event = JSON.parse(data.toString()) as Record<string, unknown>
      if (event.type === "finalize" && ++commits === 2) socket.send(JSON.stringify({ tokens: [
        { text: "one", is_final: true }, { text: "<fin>", is_final: true },
        { text: "two", is_final: true }, { text: "<fin>", is_final: true },
      ] }))
    }))
    const delivered: string[] = []
    let resolveDone!: () => void
    const done = new Promise<void>((resolve) => { resolveDone = resolve })
    let connection: ProviderConnection | undefined
    try {
      connection = await ProviderConnection.connect({ model: "meeting", apiKey: "test-key", assertAuthority: () => {},
        onFinal: (turn) => { delivered.push(turn.turnId); connection?.close(); resolveDone() },
        onFailure: () => {}, socketFactory: fixture.factory })
      connection.commitTurn("one")
      connection.commitTurn("two")
      await done
      expect(delivered).toEqual(["one"])
    } finally { connection?.close(); fixture.close() }
  })

  test("unexpected Meeting EOS closes transport and forbids later audio", async () => {
    const fixture = await server()
    let frames = 0
    fixture.ws.on("connection", (socket) => socket.on("message", (_data, binary) => {
      if (binary) frames++
      else socket.send(JSON.stringify({ tokens: [], finished: true }))
    }))
    let resolveFailure!: () => void
    const failed = new Promise<void>((resolve) => { resolveFailure = resolve })
    let connection: ProviderConnection | undefined
    try {
      connection = await ProviderConnection.connect({ model: "meeting", apiKey: "test-key", assertAuthority: () => {},
        onFinal: () => {}, onFailure: resolveFailure, socketFactory: fixture.factory })
      await failed
      expect(() => connection?.appendAudio(new Int16Array([1]))).toThrow("provider")
      expect(frames).toBe(0)
    } finally { connection?.close(); fixture.close() }
  })

  test("invalid connect options allocate no socket and factory errors stay coarse", async () => {
    let allocations = 0
    const options = { model: "standard" as const, apiKey: "test-key", assertAuthority: () => {},
      onFinal: () => {}, onFailure: () => {}, socketFactory: () => { allocations++; throw new Error("private factory detail") } }
    await expect(ProviderConnection.connect({ ...options, connectTimeoutMs: 0 })).rejects.toThrow("protocol")
    expect(allocations).toBe(0)
    await expect(ProviderConnection.connect(options)).rejects.toThrow("Grid transcription provider")
    expect(allocations).toBe(1)
  })

  test("missing configuration acknowledgement times out and closes instead of hanging", async () => {
    const fixture = await server()
    const failures: TranscriptionError[] = []
    try {
      await expect(ProviderConnection.connect({ model: "standard", apiKey: "test-key", assertAuthority: () => {},
        onFinal: () => {}, onFailure: (error) => failures.push(error), socketFactory: fixture.factory, connectTimeoutMs: 30 })).rejects.toThrow("provider")
      expect(failures.map((error) => error.code)).toEqual(["provider"])
    } finally { fixture.close() }
  })
})
