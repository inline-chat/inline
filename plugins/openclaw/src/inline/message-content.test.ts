import { describe, expect, it } from "vitest"
import { agentProgressHeader, summarizeInlineMessageContent } from "./message-content.js"

const range = (text: string, part: string) => ({ offset: BigInt(text.indexOf(part)), length: BigInt(part.length) })

function progressMessage(text: string, header: string, extra: Record<string, unknown> = {}) {
  return {
    id: 10n,
    fromId: 7n,
    date: 1_700_000_000n,
    message: text,
    sendMode: 1,
    blockContent: {
      blocks: [{ kind: { oneofKind: "disclosure", disclosure: { summary: range(text, header), kind: 0, children: [] } } }],
    },
    ...extra,
  } as any
}

describe("agent progress messages in context", () => {
  const text = "Worked for 1m 4s\nRan bun test test/login.test.ts · exit 1\n✗ login > refreshes an expired token"

  it("keeps only the header of another agent's progress message", () => {
    const message = progressMessage(text, "Worked for 1m 4s")
    expect(agentProgressHeader(message)).toBe("Worked for 1m 4s")
    expect(summarizeInlineMessageContent(message).text).toBe("[agent progress] Worked for 1m 4s")
  })

  it("reads a lone Worked for footer as progress", () => {
    const footer = "Worked for 2s"
    const message = {
      id: 11n, fromId: 7n, date: 1n, message: footer, sendMode: 1,
      blockContent: { blocks: [{ kind: { oneofKind: "footer", footer: range(footer, footer) } }] },
    } as any
    expect(summarizeInlineMessageContent(message).text).toBe("[agent progress] Worked for 2s")
  })

  it("leaves ordinary messages alone", () => {
    // A notifying message with the same shape, and a plain silent one.
    expect(agentProgressHeader(progressMessage(text, "Worked for 1m 4s", { sendMode: undefined }))).toBeUndefined()
    expect(summarizeInlineMessageContent({ id: 12n, fromId: 7n, date: 1n, message: "Checking both calendars.", sendMode: 1 } as any).text)
      .toBe("Checking both calendars.")
    const twoBlocks = progressMessage(text, "Worked for 1m 4s")
    twoBlocks.blockContent.blocks.push({ kind: { oneofKind: "paragraph", paragraph: range(text, "✗ login") } })
    expect(agentProgressHeader(twoBlocks)).toBeUndefined()
  })
})
