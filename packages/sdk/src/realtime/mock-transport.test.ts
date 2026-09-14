import { describe, expect, it } from "vitest"
import { ClientMessage } from "@inline-chat/protocol/core"
import { MockTransport } from "./mock-transport.js"
import { TransportError } from "./transport.js"

describe("MockTransport", () => {
  it("enforces connected state for send and supports reconnect/stopConnection", async () => {
    const transport = new MockTransport()
    await transport.start()
    await transport.start()

    await expect(
      transport.send(ClientMessage.create({ id: 1n, seq: 1, body: { oneofKind: undefined } })),
    ).rejects.toBeInstanceOf(TransportError)

    await transport.connect()
    await expect(transport.send(ClientMessage.create({ id: 2n, seq: 2, body: { oneofKind: undefined } }))).resolves.toBeUndefined()

    await transport.stopConnection()
    expect(transport.state).toBe("connecting")

    await transport.reconnect()
    expect(transport.state).toBe("connecting")

    await transport.stop()
    await transport.stop()
    expect(transport.state).toBe("idle")

    await transport.stopConnection()
    expect(transport.state).toBe("idle")
  })
})
