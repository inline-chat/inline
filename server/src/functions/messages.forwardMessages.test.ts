import { describe, expect, test } from "bun:test"
import type { BlockContent } from "@inline-chat/protocol/core"
import { snapshotForwardedBlockContent } from "./messages.forwardMessages"

describe("forwarded structural content", () => {
  test("turns in-flight images into an honest immutable snapshot", () => {
    const source: BlockContent = {
      blocks: [{
        kind: {
          oneofKind: "image",
          image: {
            state: {
              oneofKind: "pending",
              pending: { dimensions: { width: 640, height: 480 } },
            },
          },
        },
      }],
    }

    const forwarded = snapshotForwardedBlockContent(source)

    expect(forwarded.blocks[0]?.kind).toEqual({
      oneofKind: "image",
      image: {
        state: {
          oneofKind: "unavailable",
          unavailable: { dimensions: { width: 640, height: 480 } },
        },
      },
    })
    expect(source.blocks[0]?.kind.oneofKind === "image"
      ? source.blocks[0].kind.image.state.oneofKind
      : undefined).toBe("pending")
  })
})
