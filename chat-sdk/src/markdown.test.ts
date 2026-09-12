import { expect, test } from "bun:test"
import { renderContent } from "./content.js"
import { messageToMarkdown, messageToFormatted, richBlocksToMarkdown } from "./markdown.js"
import type { BotMessage, BotRichBlock } from "@inline-chat/bot-api-types"

import { markdownFixture } from "../test-fixtures/markdown.js"

test("normal and explicit Markdown preserve every Inline extension and whitespace", () => {
  for (const message of [markdownFixture, { markdown: markdownFixture }]) {
    expect(renderContent(message)).toEqual({ text: markdownFixture, parse_markdown: true })
  }
  expect(renderContent({ raw: markdownFixture })).toEqual({ text: markdownFixture, parse_markdown: false })
})

const raw: BotMessage = {
  message_id: 1,
  peer_id: { chat_id: 2 },
  from_id: 3,
  from: { id: 3, is_bot: false },
  date: 1800000000,
  text: "hello",
}
const blocks: BotRichBlock[] = [
  { type: "heading", size: 2, text: "Update" },
  {
    type: "paragraph",
    text: [
      { type: "bold", text: "bold" },
      " ",
      { type: "italic", text: "italic" },
      " ",
      { type: "underline", text: "underlined" },
      " ",
      { type: "highlight", text: "highlighted" },
      " ",
      { type: "strikethrough", text: "old" },
      " ",
      { type: "code", text: "a`b" },
      " ",
      { type: "math", text: "x", latex: "x^2" },
      " ",
      { type: "text_mention", text: "Mo", user: { id: 42, is_bot: false } },
      " ",
      { type: "chat_link", text: "Thread", chat_id: 5 },
    ],
  },
  { type: "blockquote", blocks: [{ type: "paragraph", text: "quote" }] },
  {
    type: "list",
    items: [{ label: "", has_checkbox: true, is_checked: true, blocks: [{ type: "paragraph", text: "done" }] }],
  },
  {
    type: "table",
    cells: [
      [
        { text: "Name", align: "left", is_header: true },
        { text: "Status", align: "right", is_header: true },
      ],
      [
        { text: "a|b", align: "left" },
        { text: "ok", align: "right" },
      ],
    ],
  },
  {
    type: "details",
    summary: "Working",
    kind: "progress",
    is_open: true,
    blocks: [
      { type: "pre", text: "const fence = '```'", language: "ts" },
      { type: "math", latex: "E=mc^2" },
    ],
  },
  { type: "photo", alt: "image", file: { file_id: "image", download_url: "https://example.com/image.png" } },
  { type: "footer", text: "Attribution" },
  { type: "divider" },
]

test("incoming rich blocks retain standard formatting and Inline extension source", () => {
  const message = { ...raw, rich_message: { blocks } }
  const source = messageToMarkdown(message)
  for (const expected of [
    "## Update",
    "**bold**",
    "*italic*",
    "<u>underlined</u>",
    "==highlighted==",
    "~~old~~",
    "``a`b``",
    "$x^2$",
    "[Mo](inline://user?id=42)",
    "[[Thread]](inline://chat?id=5)",
    "> quote",
    "- [x] done",
    "a\\|b",
    "---:",
    '<details open>\n<summary kind="progress">Working</summary>',
    "````ts",
    "$$\nE=mc^2\n$$",
    "![image](https://example.com/image.png)",
    "<footer>Attribution</footer>",
  ])
    expect(source).toContain(expected)
  const formatted = messageToFormatted(message)
  expect(formatted.children.map((node) => node.type)).toContain("heading")
  expect(JSON.stringify(formatted)).toContain('"type":"strong"')
  expect(JSON.stringify(formatted)).toContain('"type":"table"')
  expect(JSON.stringify(formatted)).toContain('"checked":true')
})

test("literal Markdown in received text is not reinterpreted, and entity offsets count UTF-16", () => {
  expect(messageToMarkdown({ ...raw, text: "*literal*" })).toBe("\\*literal\\*")
  expect(messageToMarkdown({ ...raw, text: "😀bold", entities: [{ type: "bold", offset: 2, length: 4 }] })).toBe(
    "😀**bold**",
  )
})

test("nested lists, blank lines, and code fences survive reconstruction", () => {
  expect(
    richBlocksToMarkdown([
      {
        type: "list",
        items: [
          {
            label: "1",
            value: 1,
            blocks: [
              { type: "paragraph", text: "first" },
              { type: "list", items: [{ label: "", blocks: [{ type: "paragraph", text: "child" }] }] },
            ],
          },
        ],
      },
    ]),
  ).toBe("1. first\n   \n   - child")
})

test("nested and crossing legacy entities retain their outer formatting", () => {
  expect(
    messageToMarkdown({
      ...raw,
      text: "abcd",
      entities: [
        { type: "bold", offset: 0, length: 4 },
        { type: "italic", offset: 1, length: 2 },
      ],
    }),
  ).toBe("**a*bc*d**")
  expect(
    messageToMarkdown({
      ...raw,
      text: "abcd",
      entities: [
        { type: "bold", offset: 0, length: 3 },
        { type: "italic", offset: 1, length: 3 },
      ],
    }),
  ).toBe("**a*bc****d*")
})

test("cards preserve Markdown text, tables, images and clickable links", () => {
  const rendered = renderContent({
    type: "card",
    title: "*literal title*",
    children: [
      { type: "text", content: "==highlight== <u>underline</u>" },
      { type: "table", headers: ["Task", "Status"], rows: [["A|B", "done"]], align: ["left", "right"] },
      { type: "image", url: "https://example.com/image.png", alt: "Photo" },
      { type: "actions", children: [{ type: "link-button", label: "View", url: "https://example.com" }] },
    ],
  })
  expect(rendered.parse_markdown).toBe(true)
  expect(rendered.text).toContain("\\*literal title\\*")
  expect(rendered.text).toContain("==highlight== <u>underline</u>")
  expect(rendered.text).toContain("| Task | Status |")
  expect(rendered.text).toContain("A\\|B")
  expect(rendered.text).toContain("![Photo](https://example.com/image.png)")
  expect(rendered.text).toContain("[View](https://example.com)")
  expect(() => renderContent({ type: "card", children: [{ type: "image", url: "javascript:alert(1)" }] })).toThrow(
    "HTTP(S)",
  )
})
