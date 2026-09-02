import { describe, expect, test } from "bun:test"
import { MessageEntity_Type as T, type MessageEntity } from "@inline-chat/protocol/core"
import { fromMd, toMd } from "../translation2/entities"
import { restoreCodeTrailingNewlines } from "../translation2/codeWhitespace"
import { parseMarkdownWithSourceMap } from "./parseMarkdown"

const targetTypes = [T.TEXT_URL, T.MENTION, T.GROUP_MENTION, T.THREAD, T.THREAD_TITLE]
const range = (type: T, start: number, end: number): MessageEntity => ({
  type, offset: BigInt(start), length: BigInt(end - start), entity: { oneofKind: undefined },
})
const displayMath = (start: number, end: number): MessageEntity => ({
  ...range(T.MATH, start, end), entity: { oneofKind: "math", math: { display: true } },
})
const target = (type: T, start: number, end: number): MessageEntity => {
  const item = range(type, start, end)
  switch (type) {
    case T.TEXT_URL: return { ...item, entity: { oneofKind: "textUrl", textUrl: { url: "https://example.test" } } }
    case T.MENTION: return { ...item, entity: { oneofKind: "mention", mention: { userId: 42n, agentId: 7n } } }
    case T.GROUP_MENTION: return { ...item, entity: { oneofKind: "groupMention", groupMention: { groupId: 44n } } }
    case T.THREAD: return { ...item, entity: { oneofKind: "thread", thread: { chatId: 99n } } }
    case T.THREAD_TITLE: return { ...item, entity: { oneofKind: "threadTitle", threadTitle: { spaceId: 8n, title: "Design" } } }
    default: throw new Error("Unsupported fixture target")
  }
}

describe("semantic conflicts in native Markdown export", () => {
  test("no semantic wrapper can corrupt a fenced code block", () => {
    for (const newline of ["\n", "\r\n", "\r"]) {
      const text = `before${newline}${newline}code${newline}${newline}after`
      const start = text.indexOf("code"), end = start + 4
      const pre: MessageEntity = { ...range(T.PRE, start, end), entity: { oneofKind: "pre", pre: { language: "ts" } } }
      for (const type of targetTypes) for (const [first, last] of [[0, text.length], [start, end],
        [start + 1, end - 1], [0, start + 2], [start + 2, text.length]]) {
        const entities = [target(type, first!, last!), pre]
        for (const source of [entities, [...entities].reverse()]) {
          const before = structuredClone(source), markdown = toMd(text, { entities: source })
          expect(markdown).toBe(toMd(text, { entities: [pre] }))
          const result = restoreCodeTrailingNewlines(fromMd(markdown), text, { entities: source })
          expect(result.text).toBe(text)
          expect(result.entities.entities).toEqual([pre])
          const main = parseMarkdownWithSourceMap(markdown)
          const raw = main.entities.find((item) => item.type === T.PRE)!
          expect(main.text.slice(Number(raw.offset), Number(raw.offset + raw.length))).toBe("code")
          expect(source).toEqual(before)
        }
      }
    }
    const pre: MessageEntity = { ...range(T.PRE, 0, 4), entity: { oneofKind: "pre", pre: { language: "ts" } } }
    expect(toMd("code", { entities: [pre, target(T.TEXT_URL, 0, 4)] })).toBe("```ts\ncode\n```")
  })

  test("partial or inner link ranges cannot displace or write into inline code and math", () => {
    const text = "abx^2yz"
    for (const rawType of [T.CODE, T.MATH]) for (const type of targetTypes) {
      const raw = range(rawType, 2, 5)
      for (const [start, end] of [[0, 4], [3, 7], [3, 4]]) {
        const entities = [target(type, start!, end!), raw]
        for (const source of [entities, [...entities].reverse()]) {
          const markdown = toMd(text, { entities: source })
          expect(markdown).toBe(toMd(text, { entities: [raw] }))
          expect(fromMd(markdown)).toEqual({ text, entities: { entities: [raw] } })
        }
      }
      // A link surrounding the complete inline source is representable.
      for (const [start, end] of [[0, text.length], [2, 5]]) {
        const link = target(type, start!, end!), source = { entities: [link, raw] }
        const result = fromMd(toMd(text, source))
        expect(result.text).toBe(text)
        expect(result.entities.entities.filter((item) => item.type === type)).toEqual([link])
        expect(result.entities.entities.filter((item) => item.type === rawType)).toEqual([raw])
      }
    }
  })

  test("display formulas cannot become nested link syntax", () => {
    const text = "before\n\nx^2\ny^2\n\nafter", start = text.indexOf("x^2"), end = start + 7
    const math = displayMath(start, end)
    for (const type of targetTypes) {
      const entities = [target(type, 0, text.length), math]
      const markdown = toMd(text, { entities })
      expect(markdown).toBe(toMd(text, { entities: [math] }))
      expect(fromMd(markdown)).toEqual({ text, entities: { entities: [math] } })
    }
  })

  test("overlapping semantic targets emit one outer source target and preserve independent neighbors", () => {
    const text = "abcdefghij", outer = target(T.TEXT_URL, 0, 6), neighbor = target(T.GROUP_MENTION, 6, 10)
    const bold = range(T.BOLD, 2, 8)
    for (const type of targetTypes) for (const [start, end] of [[2, 4], [2, 7]]) {
      const entities = [outer, target(type, start!, end!), neighbor, bold]
      for (const source of [entities, [...entities].reverse()]) {
        const before = structuredClone(source), markdown = toMd(text, { entities: source })
        expect(markdown).toBe(toMd(text, { entities: [outer, neighbor, bold] }))
        const result = fromMd(markdown)
        expect(result.text).toBe(text)
        expect(result.entities.entities.filter((item) => targetTypes.includes(item.type))).toEqual([outer, neighbor])
        expect(source).toEqual(before)
      }
    }
  })

  test("duplicate semantic and raw ranges are idempotent rather than nested", () => {
    for (const type of [...targetTypes, T.CODE, T.MATH, T.PRE]) {
      const text = "x^2", item = targetTypes.includes(type) ? target(type, 0, 3) : range(type, 0, 3)
      const source = Array.from({ length: 256 }, () => structuredClone(item))
      expect(toMd(text, { entities: source })).toBe(toMd(text, { entities: [item] }))
    }
  })

  test("rejecting a raw-block wrapper leaves valid neighbors and streamed prefixes intact", () => {
    const text = "before\n\ncode\n\nafter", pre: MessageEntity = { ...range(T.PRE, 8, 12),
      entity: { oneofKind: "pre", pre: { language: "ts" } } }
    const neighbors = [target(T.GROUP_MENTION, 0, 6), target(T.MENTION, 14, 19)]
    const source = { entities: [target(T.TEXT_URL, 0, text.length), ...neighbors, pre] }
    const markdown = toMd(text, source)
    const result = restoreCodeTrailingNewlines(fromMd(markdown), text, source)
    expect(result.text).toBe(text)
    expect(result.entities.entities.filter((item) => targetTypes.includes(item.type))).toEqual(neighbors)
    expect(result.entities.entities.filter((item) => item.type === T.PRE)).toEqual([pre])
    for (let end = 0; end <= markdown.length; end++) {
      const prefix = markdown.slice(0, end), parsed = parseMarkdownWithSourceMap(prefix)
      expect(parsed.sourceToOutput).toHaveLength(prefix.length + 1)
      expect(parsed.sourceToOutput.at(-1)).toBe(parsed.text.length)
      expect(parsed.sourceToOutput.every((offset, index, map) => offset >= (map[index - 1] ?? 0))).toBe(true)
      expect(parsed.entities.every((item) => item.offset >= 0n && item.length > 0n
        && item.offset + item.length <= BigInt(parsed.text.length))).toBe(true)
    }
  })

  test("nested raw spans cannot insert another delimiter into an opaque body", () => {
    const text = "abx^2yz"
    for (const first of [T.CODE, T.MATH]) for (const second of [T.CODE, T.MATH]) {
      const outer = range(first, 2, 5), inner = range(second, 3, 4)
      for (const entities of [[outer, inner], [inner, outer]]) {
        expect(toMd(text, { entities })).toBe(toMd(text, { entities: [outer] }))
        expect(fromMd(toMd(text, { entities }))).toEqual({ text, entities: { entities: [outer] } })
      }
    }
  })
})
