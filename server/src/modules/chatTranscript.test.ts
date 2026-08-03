import { describe, expect, test } from "bun:test"
import {
  renderHumanReadableChatTranscript,
  type ChatTranscriptMessage,
} from "@in/server/modules/chatTranscript"

const message = (id: number, text: string, overrides: Partial<ChatTranscriptMessage> = {}): ChatTranscriptMessage => ({
  id,
  author: "Mo",
  markdownText: text,
  forwarded: false,
  media: [],
  ...overrides,
})

describe("renderHumanReadableChatTranscript", () => {
  test("renders a clean oldest-to-newest transcript with parent context", () => {
    const result = renderHumanReadableChatTranscript({
      title: "Project *Alpha*\nNotes",
      link: "in://chat/42",
      parent: message(9, "Original question", { author: "Dena" }),
      parentChat: { title: "Planning", link: "in://chat/7" },
      messagesNewestFirst: [message(12, "Second"), message(11, "First")],
      hasOlderMessages: false,
    })

    expect(result.markdown).toContain("# Project \\*Alpha\\* Notes")
    expect(result.markdown).toContain("[Open in Inline](<in://chat/42>)")
    expect(result.markdown).toContain("## Parent message\n\nFrom [Planning](<in://chat/7>)")
    expect(result.markdown).toContain("**Dena**\n\nOriginal question")
    expect(result.markdown.indexOf("First")).toBeLessThan(result.markdown.indexOf("Second"))
    expect(result).toMatchObject({
      messageCount: 2,
      fromMessageId: 11,
      toMessageId: 12,
      hasMore: false,
      stopReason: "complete",
    })
  })

  test("keeps the newest complete messages when the output budget is reached", () => {
    const result = renderHumanReadableChatTranscript({
      title: "Long chat",
      link: "in://chat/42",
      messagesNewestFirst: [message(3, "Newest"), message(2, "x".repeat(200)), message(1, "Oldest")],
      hasOlderMessages: false,
      maxOutputBytes: 130,
    })

    expect(result.markdown).toContain("Newest")
    expect(result.markdown).not.toContain("Oldest")
    expect(result.messageCount).toBe(1)
    expect(result.fromMessageId).toBe(3)
    expect(result.hasMore).toBe(true)
    expect(result.stopReason).toBe("outputLimit")
  })

  test("reports message-limit continuation and earliest media expiration", () => {
    const result = renderHumanReadableChatTranscript({
      title: "Media",
      link: "in://chat/42",
      messagesNewestFirst: [
        message(5, "Look", {
          media: [
            { kind: "photo", label: "Photo", url: "https://cdn.test/photo", expiresAt: 200 },
            { kind: "video", label: "Video", url: "https://cdn.test/video", expiresAt: 150 },
          ],
        }),
      ],
      hasOlderMessages: true,
    })

    expect(result.markdown).toContain("![Photo](<https://cdn.test/photo>)")
    expect(result.markdown).toContain("[Video](<https://cdn.test/video>)")
    expect(result.expiresAt).toBe(150)
    expect(result.hasMore).toBe(true)
    expect(result.stopReason).toBe("messageLimit")
  })
})
