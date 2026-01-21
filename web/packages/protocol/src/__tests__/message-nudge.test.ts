import { describe, expect, it } from "bun:test"
import { Message } from "../core"
import type { Peer } from "../core"

const peer: Peer = {
  type: {
    oneofKind: "user",
    user: { userId: 42n },
  },
}

describe("Message nudge serialization", () => {
  it("round-trips nudge media", () => {
    const message = Message.create({
      id: 1n,
      fromId: 42n,
      peerId: peer,
      chatId: 10n,
      out: true,
      date: 100n,
      media: {
        media: {
          oneofKind: "nudge",
          nudge: {},
        },
      },
    })

    const encoded = Message.toBinary(message)
    const decoded = Message.fromBinary(encoded)

    expect(decoded.media?.media.oneofKind).toBe("nudge")
    expect(decoded.media?.media.nudge).toBeDefined()
  })
})
