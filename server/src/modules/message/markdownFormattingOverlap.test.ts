import { describe, expect, test } from "bun:test"
import { MessageEntity_Type as T, type MessageEntity } from "@inline-chat/protocol/core"
import { fromMd, toMd } from "../translation2/entities"
import { restoreCodeTrailingNewlines } from "../translation2/codeWhitespace"
import { encodeBlockContentToMarkdown } from "./blockContentMarkdown"
import { parseMarkdownWithSourceMap } from "./parseMarkdown"

const styles = [T.BOLD, T.ITALIC, T.UNDERLINE, T.STRIKETHROUGH, T.HIGHLIGHT]
const entity = (type: T, start: number, end: number): MessageEntity => ({
  type, offset: BigInt(start), length: BigInt(end - start), entity: { oneofKind: undefined },
})
const coverage = (entities: MessageEntity[], type: T, length: number) => Array.from({ length }, (_, offset) =>
  entities.some((item) => item.type === type && item.offset <= BigInt(offset) && BigInt(offset) < item.offset + item.length))
const parsed = (markdown: string) => {
  const main = parseMarkdownWithSourceMap(markdown), translated = fromMd(markdown)
  return [main, { text: translated.text, entities: translated.entities.entities }]
}
const expectCoverage = (text: string, source: MessageEntity[], markdown = toMd(text, { entities: source })) => {
  for (const result of parsed(markdown)) {
    expect(result.text).toBe(text)
    for (const type of styles) {
      const expected = coverage(source, type, text.length), actual = coverage(result.entities, type, text.length)
      // Existing transport represents multiline formatting per physical line.
      for (let offset = 0; offset < text.length; offset++) if (text[offset] === "\r" || text[offset] === "\n") {
        expected[offset] = actual[offset] = false
      }
      expect(actual).toEqual(expected)
    }
  }
}

describe("overlapping native formatting export", () => {
  test("all crossing style pairs retain their combined coverage in either input order", () => {
    for (const [text, firstEnd, secondStart] of [["abcdef", 4, 2], ["😀 é!", 5, 3]] as const) {
      for (const first of styles) for (const second of styles) {
        const entities = [entity(first, 0, firstEnd), entity(second, secondStart, text.length)]
        for (const source of [entities, [...entities].reverse()]) {
          const before = structuredClone(source)
          expectCoverage(text, source)
          expect(source).toEqual(before)
        }
      }
    }
  })

  test("crossing chains, redundant ranges and literal markers cannot erase text or coverage", () => {
    for (const text of ["abcdefghijklmnop", "&copy; **=literal", "hello\n  world!"]) {
      const source = styles.flatMap((type, index) => [entity(type, index, text.length - 4 + index),
        entity(type, index + 1, text.length - 5 + index)])
      expectCoverage(text, source)
      expectCoverage(text, [...source].reverse())
    }
  })

  test("a partial style overlap never displaces or splits a link or Agent target", () => {
    const text = "abMayaXY"
    const targets: MessageEntity[] = [
      { ...entity(T.TEXT_URL, 2, 6), entity: { oneofKind: "textUrl", textUrl: { url: "https://e.test/a?b=1" } } },
      { ...entity(T.MENTION, 2, 6), entity: { oneofKind: "mention", mention: { userId: 42n, agentId: 7n } } },
    ]
    for (const target of targets) for (const type of styles) for (const [start, end] of [[0, 4], [4, 8]]) {
      const source = [entity(type, start!, end!), target]
      expectCoverage(text, source)
      expectCoverage(text, [...source].reverse())
      const output = fromMd(toMd(text, { entities: source }))
      expect(output.entities.entities.filter((item) => item.type === target.type)).toEqual([target])
    }
  })

  test("mixed native selections preserve exact style coverage around an Agent link", () => {
    const text = "😀 abMaya c_d!", boundaries = Array.from({ length: text.length + 1 }, (_, index) => index).filter((index) => index !== 1)
    const mention: MessageEntity = { ...entity(T.MENTION, 5, 9),
      entity: { oneofKind: "mention", mention: { userId: 42n, agentId: 7n } } }
    let seed = 137
    const next = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed }
    for (let sample = 0; sample < 80; sample++) {
      const source = [mention]
      for (let index = 0; index < 8; index++) {
        const first = next() % (boundaries.length - 1), last = first + 1 + next() % (boundaries.length - first - 1)
        source.push(entity(styles[next() % styles.length]!, boundaries[first]!, boundaries[last]!))
      }
      const before = structuredClone(source), markdown = toMd(text, { entities: source })
      expectCoverage(text, source, markdown)
      expect(fromMd(markdown).entities.entities.filter((item) => item.type === T.MENTION)).toEqual([mention])
      expect(source).toEqual(before)
    }
  })

  test("many overlapping copies export like their equivalent five visible style ranges", () => {
    const count = 1024, text = "a".repeat(count * 2 + 128)
    const source = Array.from({ length: count }, (_, index) => entity(styles[index % styles.length]!, index * 2, index * 2 + 128))
    const minimal = styles.map((type) => {
      const ranges = source.filter((item) => item.type === type)
      return entity(type, Number(ranges[0]!.offset), Number(ranges.at(-1)!.offset + 128n))
    })
    const markdown = toMd(text, { entities: source })
    expect(markdown).toBe(toMd(text, { entities: minimal }))
    expectCoverage(text, minimal, markdown)
  })

  test("raw code and TeX win partial overlaps while formatting outside them survives", () => {
    const text = "abx^2yz"
    for (const rawType of [T.CODE, T.MATH]) for (const type of styles) {
      const raw = entity(rawType, 2, 5)
      for (const [start, end, keptStart, keptEnd] of [[0, 4, 0, 2], [3, 7, 5, 7]]) {
        const source = [entity(type, start!, end!), raw]
        const markdown = toMd(text, { entities: source })
        expectCoverage(text, [entity(type, keptStart!, keptEnd!)], markdown)
        for (const result of parsed(markdown)) expect(result.entities.filter((item) => item.type === rawType)).toEqual([raw])
      }
      // A wrapper covering the entire raw span does not insert syntax into it.
      for (const [start, end] of [[0, 7], [2, 5]]) {
        const source = [entity(type, start!, end!), raw]
        expectCoverage(text, source)
        for (const result of parsed(toMd(text, { entities: source }))) {
          expect(result.entities.filter((item) => item.type === rawType)).toEqual([raw])
        }
      }
      for (const result of parsed(toMd(text, { entities: [entity(type, 3, 4), raw] }))) {
        expect(result.text).toBe(text)
        expect(result.entities).toEqual([raw])
      }
    }
  })

  test("formatting around a whole PRE block cannot corrupt its fences or surrounding paragraphs", () => {
    for (const newline of ["\n", "\r\n", "\r"]) for (const text of ["code", `before${newline}${newline}code${newline}${newline}after`]) {
      const start = text.indexOf("code"), end = start + 4
      const pre: MessageEntity = { ...entity(T.PRE, start, end), entity: { oneofKind: "pre", pre: { language: "ts" } } }
      for (const type of styles) {
        const source = { entities: [entity(type, 0, text.length), pre] }, markdown = toMd(text, source)
        const output = restoreCodeTrailingNewlines(fromMd(markdown), text, source)
        expect(output.text).toBe(text)
        expect(output.entities.entities.filter((item) => item.type === T.PRE)).toEqual([pre])
        const styled = coverage(output.entities.entities, type, text.length)
        for (let offset = 0; offset < text.length; offset++) {
          if (text[offset] === "\r" || text[offset] === "\n") continue
          expect(styled[offset]).toBe(offset < start || offset >= end)
        }
        const main = parseMarkdownWithSourceMap(markdown)
        const blocks = main.entities.filter((item) => item.type === T.PRE)
        expect(blocks).toHaveLength(1)
        expect(main.text.slice(Number(blocks[0]!.offset), Number(blocks[0]!.offset + blocks[0]!.length))).toBe("code")
      }
    }
  })

  test("block export retains the same crossing native style coverage", () => {
    const text = "abcdef"
    const source = [entity(T.BOLD, 0, 4), entity(T.ITALIC, 2, 6), entity(T.HIGHLIGHT, 1, 5)]
    const markdown = encodeBlockContentToMarkdown({ text, entities: { entities: source },
      blockContent: { blocks: [{ kind: { oneofKind: "paragraph", paragraph: { offset: 0n, length: 6n } } }] },
    })
    expectCoverage(text, source, markdown)
  })

  test("every streamed prefix of crossing-format output has valid UTF-16 maps and ranges", () => {
    const text = "😀 &copy;!"
    const markdown = toMd(text, { entities: [entity(T.BOLD, 0, 7), entity(T.ITALIC, 3, text.length)] })
    expectCoverage(text, [entity(T.BOLD, 0, 7), entity(T.ITALIC, 3, text.length)], markdown)
    for (let end = 0; end <= markdown.length; end++) {
      const prefix = markdown.slice(0, end), result = parseMarkdownWithSourceMap(prefix)
      expect(result.sourceToOutput).toHaveLength(prefix.length + 1)
      expect(result.sourceToOutput.at(-1)).toBe(result.text.length)
      expect(result.sourceToOutput.every((offset, index, map) => offset >= (map[index - 1] ?? 0))).toBe(true)
      expect(result.entities.every((item) => item.offset >= 0n && item.length > 0n
        && item.offset + item.length <= BigInt(result.text.length))).toBe(true)
    }
  })
})
