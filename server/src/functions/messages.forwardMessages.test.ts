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

  test("a copy without a bot sender keeps a widget's title, not its HTML", () => {
    const title = { offset: 0n, length: 5n }
    const source: BlockContent = {
      blocks: [{
        kind: {
          oneofKind: "callout",
          callout: {
            kind: 0,
            children: [{
              kind: { oneofKind: "widget", widget: { widgetId: "w", title, html: "<b>x</b>", images: [], requiredGrant: 0 } },
            }],
          },
        },
      }],
    }

    const attributed = snapshotForwardedBlockContent(source)
    const copied = snapshotForwardedBlockContent(source, { keepWidgets: false })

    const child = (content: BlockContent) => content.blocks[0]?.kind.oneofKind === "callout"
      ? content.blocks[0].kind.callout.children[0]?.kind
      : undefined
    expect(child(attributed)?.oneofKind).toBe("widget")
    expect(child(copied)).toEqual({ oneofKind: "paragraph", paragraph: title })
    expect(child(source)?.oneofKind).toBe("widget")
  })
})
