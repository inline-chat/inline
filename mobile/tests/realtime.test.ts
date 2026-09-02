import { afterEach, expect, mock, test } from "bun:test"
import { ClientMessage, Method, PushNotificationProvider, ServerProtocolMessage } from "@inline-chat/protocol/core"

mock.module("../src/config/app", () => ({ appConfig: {
  apiBaseUrl: "https://inline.test", apiWsUrl: "wss://inline.test/realtime", version: "0.1.0",
} }))
mock.module("../src/observability/logger", () => ({
  createLogger: () => ({ debug() {}, info() {}, warn() {}, error() {} }),
}))

const { RealtimeClient } = await import("../src/realtime/client")
const originalWebSocket = globalThis.WebSocket
afterEach(() => { globalThis.WebSocket = originalWebSocket })

test("Android push registration completes through the current V2 wire contract", async () => {
  const sent: ClientMessage[] = []
  class FakeWebSocket {
    static OPEN = 1
    readyState = 1
    binaryType = "arraybuffer"
    onopen?: () => void
    onmessage?: (event: { data: Uint8Array }) => void
    onclose?: () => void
    constructor() { queueMicrotask(() => this.onopen?.()) }
    send(data: ArrayBuffer) {
      const message = ClientMessage.fromBinary(new Uint8Array(data))
      sent.push(message)
      const response = message.body.oneofKind === "connectionInit"
        ? ServerProtocolMessage.create({ body: { oneofKind: "connectionOpen", connectionOpen: {} } })
        : ServerProtocolMessage.create({ body: {
          oneofKind: "rpcResult",
          rpcResult: { reqMsgId: message.id, result: { oneofKind: "registerDevice", registerDevice: {} } },
        } })
      queueMicrotask(() => this.onmessage?.({ data: ServerProtocolMessage.toBinary(response) }))
    }
    close() { this.readyState = 3; this.onclose?.() }
  }
  globalThis.WebSocket = FakeWebSocket as unknown as typeof WebSocket
  const client = new RealtimeClient("test-token")
  try {
    await client.updateAndroidPushToken("ExponentPushToken[test]")
    expect(sent[0]?.body).toEqual({
      oneofKind: "connectionInit",
      connectionInit: { token: "test-token", layer: 2, clientVersion: "0.1.0" },
    })
    const call = sent[1]?.body
    expect(call?.oneofKind).toBe("rpcCall")
    if (call?.oneofKind !== "rpcCall") throw new Error("Missing registration RPC")
    expect(call.rpcCall.method).toBe(Method.REGISTER_DEVICE)
    expect(call.rpcCall.input).toEqual({
      oneofKind: "registerDevice",
      registerDevice: {
        applePushToken: "",
        notificationMethod: {
          provider: PushNotificationProvider.EXPO_ANDROID,
          method: { oneofKind: "expoAndroid", expoAndroid: { expoPushToken: "ExponentPushToken[test]" } },
        },
      },
    })
  } finally {
    client.close()
  }
})
