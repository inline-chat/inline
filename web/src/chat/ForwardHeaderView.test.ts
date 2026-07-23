import { chatId, messageId, userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { forwardTargetPeer } from "./ForwardNavigation"

describe("forwardTargetPeer", () => {
  it("matches Inline macOS private-forward peer selection", () => {
    const currentPeer = {
      peerKind: "user" as const,
      peerId: userId(8),
    }
    expect(
      forwardTargetPeer(
        {
          fromPeer: currentPeer,
          fromId: userId(9),
          fromMessageId: messageId(4),
        },
        currentPeer,
        userId(7),
      ),
    ).toEqual({ peerKind: "user", peerId: "9" })
    expect(
      forwardTargetPeer(
        {
          fromPeer: currentPeer,
          fromId: userId(7),
          fromMessageId: messageId(4),
        },
        currentPeer,
        userId(7),
      ),
    ).toEqual(currentPeer)
  })

  it("preserves a forwarded thread route", () => {
    expect(
      forwardTargetPeer(
        {
          fromPeer: {
            peerKind: "chat",
            peerId: chatId(90),
          },
          fromId: userId(9),
          fromMessageId: messageId(4),
        },
        { peerKind: "user", peerId: userId(8) },
        userId(7),
      ),
    ).toEqual({ peerKind: "chat", peerId: "90" })
  })
})
