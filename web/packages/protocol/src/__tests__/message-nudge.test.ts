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

    const decodedMedia = decoded.media?.media
    expect(decodedMedia?.oneofKind).toBe("nudge")

    if (!decodedMedia || decodedMedia.oneofKind !== "nudge") {
      throw new Error("Expected decoded message media to be a nudge")
    }

    expect(decodedMedia.nudge).toBeDefined()
  })
})
