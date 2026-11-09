import { describe, expect, it } from "vitest"
import {
  adaptInlineVisibleCopy,
  buildInlineInboundFormattingHints,
  buildInlineChatMarkdownLink,
  buildInlineSystemPrompt,
  buildInlineThreadMarkdownLink,
  buildInlineThreadTitleMarkdownLink,
  buildInlineUserMarkdownLink,
  sanitizeInlineOutgoingText,
} from "./message-formatting"

describe("inline/message-formatting", () => {
  it("keeps GroupSystemPrompt for custom config guidance only", () => {
    const prompt = buildInlineSystemPrompt("Keep replies short.")

    expect(prompt).toBe("Keep replies short.")
    expect(buildInlineSystemPrompt()).toBe("")
  })

  it("builds structured inbound formatting hints for OpenClaw metadata", () => {
    expect(buildInlineInboundFormattingHints()).toEqual({
      text_markup: "inline_markdown",
      rules: expect.arrayContaining([
        "Use Inline's supported Markdown: emphasis, inline or fenced code, links, headings, lists or checklists, quotes, tables, separators, and HTTP(S) images.",
        "Do not rely on strikethrough, footnotes, or arbitrary HTML; unrecognized or ambiguous incomplete syntax remains visible text.",
        "Use ordinary Markdown tables for genuinely tabular data; never put a table in a fenced code block.",
        'For collapsible work, use <details open> followed by <summary>Title</summary>, body Markdown, and </details>; add kind="progress" to summary only while work is in progress.',
        "Use <footer>Attribution or brief metadata</footer> for a short message footer.",
        "Use plain URLs or markdown links; do not wrap bare URLs in inline code or backticks.",
        "Keep ordinary quoted prose, names, titles, statuses, and natural-language labels as plain text; quotation marks do not make text code.",
        "Mention Inline users as [@FirstName](inline://user?id=123), falling back to [@username](inline://user?id=123). Use inline://user?username=username only when the user id is unavailable, and never show user:<id> as the visible label.",
        "Link Inline chats/threads with markdown links like [Planning](inline://chat?id=123) or [Planning](inline://thread?id=123); use inline://thread?space_id=7 when only the title and space are known.",
      ]),
    })
  })

  it("builds Inline markdown links for users, chats, and threads", () => {
    expect(buildInlineUserMarkdownLink({ userId: "99", label: "Alice" })).toBe(
      "[@Alice](inline://user?id=99)",
    )
    expect(buildInlineUserMarkdownLink({ userId: "99", username: "alice" })).toBe(
      "[@alice](inline://user?id=99)",
    )
    expect(buildInlineUserMarkdownLink({ userId: "99" })).toBe(
      "[@user](inline://user?id=99)",
    )
    expect(buildInlineChatMarkdownLink({ chatId: "7", title: "Alice DM" })).toBe(
      "[Alice DM](inline://chat?id=7)",
    )
    expect(buildInlineThreadMarkdownLink({ threadId: "8", title: "Eng Group" })).toBe(
      "[Eng Group](inline://thread?id=8)",
    )
    expect(buildInlineThreadTitleMarkdownLink({ spaceId: "22", title: "Eng Group" })).toBe(
      "[Eng Group](inline://thread?space_id=22)",
    )
    expect(
      buildInlineThreadTitleMarkdownLink({
        spaceId: "22",
        title: "Project Plan",
        label: "the thread",
      }),
    ).toBe("[the thread](inline://thread?space_id=22&title=Project%20Plan)")
  })

  it("strips inline code formatting from bare URLs only", () => {
    expect(
      sanitizeInlineOutgoingText("See `https://example.com/docs` and `http://example.com/a?b=1`."),
    ).toBe("See https://example.com/docs and http://example.com/a?b=1.")
  })

  it("preserves non-URL inline code spans", () => {
    expect(sanitizeInlineOutgoingText("Run `bun test` then open `src/index.ts`.")).toBe(
      "Run `bun test` then open `src/index.ts`.",
    )
  })

  it("adapts shared native-channel command copy for Inline", () => {
    expect(
      adaptInlineVisibleCopy(
        "/focus - Bind this thread (Discord) or topic/conversation (Telegram) to a session target.",
      ),
    ).toBe("/focus - Bind this Inline conversation to a session target.")
    expect(
      sanitizeInlineOutgoingText(
        "/unfocus - Remove the current thread (Discord) or topic/conversation (Telegram) binding.",
      ),
    ).toBe("/unfocus - Remove the current Inline conversation binding.")
  })

  it("adapts generic shared command copy variants for Inline", () => {
    expect(adaptInlineVisibleCopy("/bind - Bind this thread or topic/conversation to a session target")).toBe(
      "/bind - Bind this Inline conversation to a session target.",
    )
    expect(
      adaptInlineVisibleCopy("/unbind - Remove the current thread or topic/conversation binding"),
    ).toBe("/unbind - Remove the current Inline conversation binding.")
  })

  it("shortens OpenClaw's notices and menus for Inline", () => {
    expect(adaptInlineVisibleCopy("✅ Approval allow-once submitted for 6b28e27d-ff13-4b89-bf9c-2e6d6e29215c.")).toBe("Allowed once.")
    expect(adaptInlineVisibleCopy("✅ Approval deny submitted for 297c1458-1ee9-472b-be47-f04810a72fd8.")).toBe("Denied.")
    expect(adaptInlineVisibleCopy("Approval required. I sent the approval request to Inline DMs, not this chat.")).toBe("Waiting for approval in your DM.")
    expect(adaptInlineVisibleCopy("⚠️ OpenClaw couldn't produce or deliver a reply. Please try again. If this keeps happening, ask the operator to check the gateway logs. Reference: ba72cfc1-e8ba-4470-af43-8f7f2d7bb86f.")).toBe("⚠️ Couldn't answer that. Try again.")
    expect(adaptInlineVisibleCopy("⚠️ The AI service returned an empty reply. Please try again.")).toBe("⚠️ Couldn't answer that. Try again.")
    expect(adaptInlineVisibleCopy("Current thinking level: high.\nChoose level for /think.\nOptions: default, off, low, medium, high, xhigh, max.")).toBe("Thinking: high")
    expect(adaptInlineVisibleCopy([
      "Current: anthropic/claude-sonnet-5-5",
      "Think: high (change with /think <level>)",
      "Tap below to select a model, or use:",
      "/model <provider/model> -s for this session only",
      "/model <provider/model> -a to update this agent's default",
      "/model <provider/model> -g to update the global default",
      "/model <provider/model> --runtime <runtime> -s to switch harnesses",
      "/model status for details",
    ].join("\n"))).toBe("Model: anthropic/claude-sonnet-5-5\nThinking: high")
    // Agent text that only mentions these words is left alone.
    expect(adaptInlineVisibleCopy("The approval required. I sent it.")).toBe("The approval required. I sent it.")
  })
})
