import { describe, expect, test } from "bun:test"
import { MessageEntity_Type, type MessageEntity } from "@inline-chat/protocol/core"
import { fromMd } from "../translation2/entities"
import { parseBlockContent, validateBlockContent } from "./blockContent"
import { parseMarkdownWithSourceMap } from "./parseMarkdown"
import { processMessageText } from "./processText"

const values = (text: string, entities: MessageEntity[], type: MessageEntity_Type) => entities
  .filter((item) => item.type === type)
  .map((item) => text.slice(Number(item.offset), Number(item.offset + item.length)))
const parsers = (source: string) => {
  const main = parseMarkdownWithSourceMap(source), translated = fromMd(source)
  return [main, { text: translated.text, entities: translated.entities.entities }]
}
const styles = [
  ["~~", "~~", MessageEntity_Type.STRIKETHROUGH],
  ["==", "==", MessageEntity_Type.HIGHLIGHT],
  ["<u>", "</u>", MessageEntity_Type.UNDERLINE],
] as const

describe("resolved reference labels are opaque to surrounding style delimiters", () => {
  test("full, collapsed, and shortcut links retain inner and outer styles", () => {
    for (const [open, close, type] of styles) {
      const label = `${open}label${close}`
      for (const [link, definition] of [[`[${label}][id]`, "id"], [`[${label}][]`, label], [`[${label}]`, label]]) {
        const source = `${open}before ${link} after${close}\n\n[${definition}]: https://e.test`
        for (const result of parsers(source)) {
          expect(result.text).toBe("before label after\n\n")
          expect(values(result.text, result.entities, type)).toEqual(["before label after", "label"])
          expect(values(result.text, result.entities, MessageEntity_Type.TEXT_URL)).toEqual(["label"])
        }
      }
    }
  })

  test("padded emphasis compatibility uses the same reference boundary", () => {
    for (const marker of ["*", "**", "_", "__"]) {
      const type = marker.length === 1 ? MessageEntity_Type.ITALIC : MessageEntity_Type.BOLD
      const source = `${marker} padded [${marker}label${marker}][id] ${marker}\n\n[id]: https://e.test`
      for (const result of parsers(source)) {
        expect(result.text).toBe(" padded label \n\n")
        expect(values(result.text, result.entities, type)).toEqual([" padded label ", "label"])
        expect(values(result.text, result.entities, MessageEntity_Type.TEXT_URL)).toEqual(["label"])
      }
    }
  })

  test("legacy adjacent emphasis keeps styled reference labels and Agent ranges", () => {
    for (const marker of ["*", "**"]) {
      const type = marker.length === 1 ? MessageEntity_Type.ITALIC : MessageEntity_Type.BOLD
      const source = `😀 ${marker}one${marker}${marker}@Maya [${marker}label${marker}][id] tail${marker}\n\n[id]: https://e.test`
      for (const result of parsers(source)) {
        expect(result.text).toBe("😀 one@Maya label tail\n\n")
        expect(values(result.text, result.entities, type)).toEqual(["one", "@Maya label tail", "label"])
        expect(values(result.text, result.entities, MessageEntity_Type.TEXT_URL)).toEqual(["label"])
      }
      const mention: MessageEntity = { type: MessageEntity_Type.MENTION, offset: BigInt(source.indexOf("@Maya")), length: 5n,
        entity: { oneofKind: "mention", mention: { userId: 4n, agentId: 8n } } }
      const parsed = processMessageText({ text: source, entities: { entities: [mention] } })
      expect(values(parsed.text, parsed.entities!.entities, MessageEntity_Type.MENTION)).toEqual(["@Maya"])
      expect(parsed.entities!.entities.find((item) => item.type === MessageEntity_Type.MENTION)?.entity).toEqual(mention.entity)
    }
  })

  test("quote and table projections keep reference styles within their original surface", () => {
    for (const [open, close, type] of styles) {
      const body = `${open}before [${open}label${close}][id] after${close}`
      for (const source of [`> ${body}\n\n[id]: https://e.test`, `| ${body} | next |\n| --- | --- |\n| 😀 | x |\n\n[id]: https://e.test`]) {
        for (const result of parsers(source)) {
          expect(values(result.text, result.entities, type)).toEqual(["before label after", "label"])
          expect(values(result.text, result.entities, MessageEntity_Type.TEXT_URL)).toEqual(["label"])
        }
        const main = parseMarkdownWithSourceMap(source), rich = parseBlockContent(source, main)!
        expect(() => validateBlockContent(main.text, rich.blockContent)).not.toThrow()
        expect(rich.warnings).toBeUndefined()
      }
    }
  })

  test("unresolved references do not acquire link semantics", () => {
    for (const [open, close] of styles) {
      const source = `${open}before [label][missing] after${close}`
      for (const result of parsers(source)) {
        expect(result.text).toBe("before [label][missing] after")
        expect(values(result.text, result.entities, MessageEntity_Type.TEXT_URL)).toEqual([])
      }
    }
  })

  test("streaming late definitions preserves monotonic UTF-16 maps and valid entities", () => {
    for (const source of ["😀 ==before [==label==][id] after==\n\n[id]: https://e.test", "*one**@Maya [*label*][id] tail*\n\n[id]: https://e.test"]) {
      for (let end = 0; end <= source.length; end++) {
        const prefix = source.slice(0, end), parsed = parseMarkdownWithSourceMap(prefix)
        expect(parsed.sourceToOutput).toHaveLength(prefix.length + 1)
        expect(parsed.sourceToOutput.at(-1)).toBe(parsed.text.length)
        expect(parsed.sourceToOutput.every((offset, index, map) => Number.isInteger(offset) && offset >= (map[index - 1] ?? 0))).toBe(true)
        for (const result of parsers(prefix)) {
          expect(result.entities.every((item) => item.offset >= 0n && item.length > 0n && item.offset + item.length <= BigInt(result.text.length))).toBe(true)
        }
      }
    }
  })
})
