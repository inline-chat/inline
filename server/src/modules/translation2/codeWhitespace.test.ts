import { describe, expect, test } from "bun:test"
import { MessageEntity_Type, type MessageEntities, type MessageEntity } from "@inline-chat/protocol/core"
import { parseMarkdown } from "../message/parseMarkdown"
import { restoreCodeTrailingNewlines } from "./codeWhitespace"
import { fromMd, toMd } from "./entities"

const pre = (offset: number, body: string): MessageEntity => ({
  type: MessageEntity_Type.PRE, offset: BigInt(offset), length: BigInt(body.length),
  entity: { oneofKind: "pre", pre: { language: "ts" } },
})

describe("source-verified translation code whitespace", () => {
  test("standalone PRE exports closed fences without persisting delimiter backticks", () => {
    for (const body of ["hello", "hello\nworld", " x ", "x\n\ny", "😀 é", "const x = ```;", "\t x\t"]) {
      const entities = { entities: [pre(0, body)] }, markdown = toMd(body, entities)
      const parsed = fromMd(markdown)
      expect(parsed.text).toBe(`${body}\n`)
      expect(parsed.entities.entities).toEqual([pre(0, `${body}\n`)])
      expect(restoreCodeTrailingNewlines(parsed, body, entities)).toEqual({ text: body, entities })
      const main = parseMarkdown(markdown)
      expect(main.text).toBe(body.trim())
      expect(main.entities.map((entity) => entity.type)).toEqual([MessageEntity_Type.PRE])
    }
  })

  test("original LF, CRLF, CR, blank lines, and whitespace remain exact", () => {
    for (const body of ["x\n", "x\n\n", "x\r\n", "x\r", "x\r\ny", " \n ", "\n", "\r\n"]) {
      const entities = { entities: [pre(0, body)] }
      expect(restoreCodeTrailingNewlines(fromMd(toMd(body, entities)), body, entities)).toEqual({ text: body, entities })
    }
  })

  test("block boundaries use LF, CRLF, or CR without changing surrounding text", () => {
    for (const newline of ["\n", "\r\n", "\r"]) {
      const prefix = `before${newline}${newline}`, code = "const x = 1", text = `${prefix}${code}${newline}${newline}after`
      const entities = { entities: [pre(prefix.length, code)] }
      expect(restoreCodeTrailingNewlines(fromMd(toMd(text, entities)), text, entities)).toEqual({ text, entities })
    }
  })

  test("removal remaps later styles and Agent mentions without mutating either input", () => {
    const code = "😀 value", text = `${code}\n\n@Maya`
    const mention: MessageEntity = { type: MessageEntity_Type.MENTION, offset: BigInt(code.length + 2), length: 5n,
      entity: { oneofKind: "mention", mention: { userId: 4n, agentId: 8n } } }
    const entities: MessageEntities = { entities: [pre(0, code), mention, {
      type: MessageEntity_Type.BOLD, offset: mention.offset, length: mention.length, entity: { oneofKind: undefined },
    }] }
    const parsed = fromMd(toMd(text, entities)), beforeParsed = structuredClone(parsed), beforeEntities = structuredClone(entities)
    expect(restoreCodeTrailingNewlines(parsed, text, entities)).toEqual({ text, entities })
    expect(parsed).toEqual(beforeParsed)
    expect(entities).toEqual(beforeEntities)
  })

  test("changed code and ambiguous original trailing newlines are left unchanged", () => {
    const changed = fromMd("```ts\nchanged\n```")
    expect(restoreCodeTrailingNewlines(changed, "original", { entities: [pre(0, "original")] })).toBe(changed)
    const source = "x\n\nx\n", entities = { entities: [pre(0, "x"), pre(3, "x\n")] }
    const parsed = fromMd(toMd(source, entities))
    expect(restoreCodeTrailingNewlines(parsed, source, entities)).toBe(parsed)
  })

  test("malformed or non-code source ranges cannot authorize whitespace removal", () => {
    const parsed = fromMd("```ts\nx\n```")
    const invalid = { entities: [pre(-1, "xx"), pre(0, "xx"), { ...pre(0, "x"), type: MessageEntity_Type.CODE }] }
    expect(restoreCodeTrailingNewlines(parsed, "x", invalid)).toBe(parsed)
    expect(restoreCodeTrailingNewlines(parsed, "x", null)).toBe(parsed)
  })

  test("existing embedded PRE transport remains byte-for-byte unchanged", () => {
    const text = "before code after", entities = { entities: [pre(7, "code")] }
    expect(toMd(text, entities)).toBe("before ```ts\ncode``` after")
    expect(fromMd(toMd(text, entities))).toEqual({ text, entities })
  })
})
