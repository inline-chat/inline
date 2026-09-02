import { describe, expect, test } from "bun:test"
import { MessageEntity_Type as T, type MessageEntity } from "@inline-chat/protocol/core"
import { fromMd, toMd } from "."
import { groupMentionMdUrl, parseGroupMentionMdUrl } from "./groupMention"
import { encodeBlockContentToMarkdown } from "../../message/blockContentMarkdown"
import { parseMarkdownWithSourceMap } from "../../message/parseMarkdown"

const group = (offset = 3n, length = 4n, groupId = 44n): MessageEntity => ({
  type: T.GROUP_MENTION, offset, length, entity: { oneofKind: "groupMention", groupMention: { groupId } },
})

describe("distinct group-mention Markdown transport", () => {
  test("encodes positive Int64 targets without conflating groups with users", () => {
    for (const id of [1n, 44n, 9_223_372_036_854_775_807n]) {
      expect(groupMentionMdUrl(id)).toBe(`inline://group/${id}`)
      expect(parseGroupMentionMdUrl(`inline://group/${id}`)).toBe(id)
      expect(parseGroupMentionMdUrl(`INLINE://GROUP/${id}`)).toBe(id)
    }
    for (const id of [0n, -1n, 9_223_372_036_854_775_808n]) expect(groupMentionMdUrl(id)).toBeNull()
  })

  test("malformed or ambiguous group links stay ordinary URLs", () => {
    for (const url of ["inline://group/0", "inline://group/-1", "inline://group/01", "inline://group/1/",
      "inline://group?id=1", "inline://group/1?agent_id=2", "inline://group/1#x", "inline://group/%31",
      "inline://group/9223372036854775808", "inline://group/" + "9".repeat(10000),
      "inline://user/1", "inline://user@group/1", "inline://group:80/1", "inline://group/1\n", " inline://group/1"]) {
      expect(parseGroupMentionMdUrl(url)).toBeNull()
    }
    for (const url of ["inline://group/0", "inline://group/1?agent_id=2", "inline://group/9223372036854775808"]) {
      const result = fromMd(`[team](${url})`)
      expect(result.text).toBe("team")
      expect(result.entities.entities.map((item) => item.type)).toEqual([T.TEXT_URL])
    }
  })

  test("round-trips exact Unicode ranges and group identity without mutating the source", () => {
    const text = "😀 @eng hello", source = { entities: [group()] }, before = structuredClone(source)
    const markdown = toMd(text, source)
    expect(markdown).toBe("😀 [@eng](inline://group/44) hello")
    expect(fromMd(markdown)).toEqual({ text, entities: source })
    expect(source).toEqual(before)
    const main = parseMarkdownWithSourceMap(markdown)
    expect(main.text).toBe(text)
    // Send parsing keeps a URL until the authorized message boundary resolves it.
    expect(main.entities).toEqual([{ type: T.TEXT_URL, offset: 3n, length: 4n,
      entity: { oneofKind: "textUrl", textUrl: { url: "inline://group/44" } } }])
    expect(fromMd("@eng").entities.entities.every((item) => item.type !== T.GROUP_MENTION)).toBe(true)
  })

  test("crossing styles cannot split or erase a group target", () => {
    const text = "abTeamXY", mention = group(2n, 4n)
    for (const type of [T.BOLD, T.ITALIC, T.UNDERLINE, T.STRIKETHROUGH, T.HIGHLIGHT]) {
      const style: MessageEntity = { type, offset: 0n, length: 4n, entity: { oneofKind: undefined } }
      const result = fromMd(toMd(text, { entities: [style, mention] }))
      expect(result.text).toBe(text)
      expect(result.entities.entities.filter((item) => item.type === T.GROUP_MENTION)).toEqual([mention])
      for (let offset = 0; offset < text.length; offset++) {
        expect(result.entities.entities.some((item) => item.type === type && item.offset <= BigInt(offset)
          && BigInt(offset) < item.offset + item.length)).toBe(offset < 4)
      }
    }
  })

  test("paragraph block export uses the same group transport", () => {
    const text = "😀 @eng", entities = { entities: [group()] }
    const markdown = encodeBlockContentToMarkdown({ text, entities,
      blockContent: { blocks: [{ kind: { oneofKind: "paragraph", paragraph: { offset: 0n, length: BigInt(text.length) } } }] },
    })
    expect(fromMd(markdown)).toEqual({ text, entities })
  })

  test("invalid group payloads preserve visible text without inventing a target", () => {
    for (const mention of [group(0n, 4n, 0n), group(0n, 4n, -1n), group(0n, 4n, 1n << 80n),
      { ...group(0n, 4n), entity: { oneofKind: undefined } } satisfies MessageEntity]) {
      expect(toMd("team", { entities: [mention] })).toBe("team")
    }
  })

  test("code and math never turn a literal group URL into a mention", () => {
    const source = "[team](inline://group/44)"
    for (const delimiter of ["`", "$"]) {
      const result = fromMd(delimiter + source + delimiter)
      expect(result.text).toBe(source)
      expect(result.entities.entities.every((item) => item.type !== T.GROUP_MENTION)).toBe(true)
    }
  })
})
