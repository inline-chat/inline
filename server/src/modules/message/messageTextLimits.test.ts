import { describe, expect, test } from "bun:test"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { processOutgoingText } from "./processOutgoingText"
import { messageTextLimits, validateOutgoingMessageText } from "./messageTextLimits"

describe("outgoing message text limits", () => {
  test("accepts the exact UTF-16 boundary", () => {
    expect(() => validateOutgoingMessageText("a".repeat(messageTextLimits.utf16Units))).not.toThrow()
  })

  test("rejects excess UTF-16 before Markdown parsing", async () => {
    const text = "**" + "a".repeat(messageTextLimits.utf16Units) + "**"
    await expect(processOutgoingText({ text, entities: undefined, parseMarkdown: true }))
      .rejects.toMatchObject({ code: RealtimeRpcError.Code.BAD_REQUEST })
  })

  test("accepts the full UTF-16 ceiling with multibyte text", () => {
    const text = "漢".repeat(messageTextLimits.utf16Units)
    expect(Buffer.byteLength(text, "utf8")).toBeLessThan(messageTextLimits.utf8Bytes)
    expect(() => validateOutgoingMessageText(text)).not.toThrow()
  })

  test("parses one 90k collapsed progress message without flattening disclosures", async () => {
    const rows: string[] = []
    const render = (items: string[]) =>
      `<details open>\n<summary kind="progress">Working</summary>\n\n${items.join("\n\n")}\n</details>`
    while (true) {
      const index = rows.length + 1
      const next = [
        ...rows,
        `<details>\n<summary>Ran command ${index}</summary>\n\n${"x".repeat(850)}\n</details>`,
      ]
      if (render(next).length > 95_000) break
      rows.push(next[next.length - 1]!)
    }
    const source = render(rows)
    expect(source.length).toBeGreaterThan(90_000)

    const result = await processOutgoingText({
      text: source,
      entities: undefined,
      parseMarkdown: true,
    })
    expect(result.blockContent?.blocks).toHaveLength(1)
  })
})
