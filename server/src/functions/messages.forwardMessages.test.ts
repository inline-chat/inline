import { describe, expect, test } from "bun:test"
import { BlockDecisionState, type BlockContent } from "@inline-chat/protocol/core"
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

  test("a copy carries no actions, so its blocks name none as buttons", () => {
    const title = { offset: 0n, length: 4n }
    const source: BlockContent = {
      blocks: [
        { kind: { oneofKind: "planProposal", planProposal: { title, children: [], state: 1, actionIds: ["approve"] } } },
        { kind: { oneofKind: "nextStep", nextStep: { recap: title, actionIds: ["yes"], blocking: true } } },
        { kind: { oneofKind: "review", review: { verdict: 0, findings: [{ title, priority: 1, confidence: 0, outcome: 0, actionId: "fix" }] } } },
      ],
    }

    const forwarded = snapshotForwardedBlockContent(source)

    expect(JSON.stringify(forwarded, (_, value) => typeof value === "bigint" ? Number(value) : value)).not.toMatch(/approve|"yes"|fix/)
    expect(source.blocks[0]?.kind.oneofKind === "planProposal" && source.blocks[0].kind.planProposal.actionIds).toEqual(["approve"])
  })

  test("an open decision reads as expired in the copy; a made one is kept", () => {
    const title = { offset: 0n, length: 4n }
    const source: BlockContent = {
      blocks: [
        { kind: { oneofKind: "planProposal", planProposal: { title, children: [], state: BlockDecisionState.PENDING, actionIds: ["approve"] } } },
        { kind: { oneofKind: "approval", approval: { subject: 1, title, children: [], state: BlockDecisionState.ACCEPTED, actionIds: [] } } },
        { kind: { oneofKind: "taskSuggestion", taskSuggestion: {
          title, state: BlockDecisionState.ACCEPTED, actionIds: [],
          startedPeer: { type: { oneofKind: "chat", chat: { chatId: 9n } } },
        } } },
        { kind: { oneofKind: "nextStep", nextStep: { recap: title, actionIds: ["yes"], blocking: true } } },
      ],
    }

    const kinds = snapshotForwardedBlockContent(source).blocks.map((block) => block.kind)

    expect(kinds[0]?.oneofKind === "planProposal" && kinds[0].planProposal.state).toBe(BlockDecisionState.EXPIRED)
    expect(kinds[1]?.oneofKind === "approval" && kinds[1].approval.state).toBe(BlockDecisionState.ACCEPTED)
    expect(kinds[2]?.oneofKind === "taskSuggestion" && kinds[2].taskSuggestion.startedPeer).toBeUndefined()
    expect(kinds[3]?.oneofKind === "nextStep" && kinds[3].nextStep.blocking).toBe(false)
  })
})
