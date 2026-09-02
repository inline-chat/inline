import { MessageEntity_Type, type BlockText, type MessageEntity } from "@inline-chat/protocol/core"
import { describe, expect, test } from "bun:test"
import { fromMd } from "../translation2/entities/fromMarkdown"
import { toMd } from "../translation2/entities/toMarkdown"
import { parseBlockContent, validateBlockContent } from "./blockContent"
import { parseMarkdown, parseMarkdownWithSourceMap } from "./parseMarkdown"
import { processMessageText } from "./processText"
import { processOutgoingText } from "./processOutgoingText"

const urls = (entities: MessageEntity[]) => entities.flatMap((entity) => entity.type === MessageEntity_Type.TEXT_URL
  && entity.entity.oneofKind === "textUrl" ? [entity.entity.textUrl.url] : [])
const slice = (text: string, range: BlockText | undefined) => range
  ? text.slice(Number(range.offset), Number(range.offset + range.length)) : undefined

describe("canonical Markdown references", () => {
  test("full, collapsed, shortcut, Unicode, escaped, and multiline labels use first-definition semantics", () => {
    const cases: [string, string, string][] = [
      ["[label][ID]\n\n[id]: https://e.test\n[id]: https://ignored.test", "label\n\n\n", "https://e.test"],
      ["[label][]\n\n[label]: <https://e.test/a b> 'title'", "label\n\n", "https://e.test/a b"],
      ["[label]\n\n[label]: https://e.test", "label\n\n", "https://e.test"],
      ["[label][one  two]\n\n[ONE\ntwo]: https://e.test", "label\n\n", "https://e.test"],
      ["[label][ẞ]\n\n[ss]: https://e.test", "label\n\n", "https://e.test"],
      [String.raw`[la\]bel][r]\n\n[r]: https://e.test/a\)b?x=1&amp;y=2`.replaceAll(String.raw`\n`, "\n"),
        "la]bel\n\n", "https://e.test/a)b?x=1&y=2"],
      ["[label][r]\n\n[r]:\n  <https://e.test>\n  \"multiline\n  title\"", "label\n\n", "https://e.test"],
    ]
    for (const [source, text, url] of cases) {
      const main = parseMarkdownWithSourceMap(source), translated = fromMd(source)
      expect(main.text).toBe(text)
      expect(translated.text).toBe(text)
      expect(urls(main.entities)).toEqual([url])
      expect(urls(translated.entities.entities)).toEqual([url])
      const rich = parseBlockContent(source, main)!
      expect(rich.blockContent.blocks.map((block) => block.kind.oneofKind)).toEqual(["paragraph"])
      expect(() => validateBlockContent(main.text, rich.blockContent)).not.toThrow()
      for (let index = 1; index < main.sourceToOutput.length; index++) {
        expect(main.sourceToOutput[index]! >= main.sourceToOutput[index - 1]!).toBe(true)
      }
      expect(main.sourceToOutput.at(-1)).toBe(text.length)
    }
  })

  test("nested and outer styles retain references without reparsing definitions as formatting", () => {
    for (const source of ["**[label][r]**", "[**label**][r]", "<u>==[~~label~~][r]==</u>", "**before [label][r] after**"]) {
      const markdown = source + "\n\n[r]: https://e.test/**url**"
      const main = parseMarkdown(markdown), translated = fromMd(markdown)
      expect(urls(main.entities)).toEqual(["https://e.test/**url**"])
      expect(urls(translated.entities.entities)).toEqual(["https://e.test/**url**"])
      expect(translated.text).toBe(main.text)
      expect(main.text).not.toContain("[r]")
      expect(main.entities.some((entity) => entity.type === MessageEntity_Type.BOLD || entity.type === MessageEntity_Type.UNDERLINE)).toBe(true)
    }
  })

  test("TeX brackets are opaque while shortcut reference identifiers remain unchanged", () => {
    const cases = [
      "$[inner]$ [outer][id]\n\n[inner]: https://wrong.test\n[id]: https://e.test",
      "[$[inner]$][id]\n\n[inner]: https://wrong.test\n[id]: https://e.test",
      "[$x$]\n\n[$x$]: https://e.test",
      "[$x$][]\n\n[$x$]: https://e.test",
      "[$😀$][id]\n\n[id]: https://e.test",
    ]
    for (const source of cases) {
      const main = parseMarkdownWithSourceMap(source), translated = fromMd(source)
      expect(urls(main.entities)).toEqual(["https://e.test"])
      expect(urls(translated.entities.entities)).toEqual(["https://e.test"])
      expect(translated.text).toBe(main.text)
      expect(main.entities.filter((entity) => entity.type === MessageEntity_Type.MATH)).toHaveLength(1)
      expect(parseBlockContent(source, main)?.imageSources).toEqual([])
    }
  })

  test("code and multiline math cannot supply or consume reference definitions", () => {
    for (const source of [
      "[label][hidden]\n\n```\n[hidden]: https://wrong.test\n```",
      "[label][hidden]\n\n    [hidden]: https://wrong.test",
      "[label][hidden]\n\n$$\n[hidden]: https://wrong.test\n$$",
    ]) {
      expect(urls(parseMarkdown(source).entities)).toEqual([])
      expect(urls(fromMd(source).entities.entities)).toEqual([])
      expect(parseMarkdown(source).text).toContain("[label][hidden]")
    }
    const source = "    [label][id]\n\n[id]: https://e.test"
    const main = parseMarkdown(source)
    expect(main.text).toBe("[label][id]\n\n")
    expect(main.entities.map((entity) => entity.type)).toEqual([MessageEntity_Type.PRE])
  })

  test("reference images share normal image jobs, dimensions, albums, and URL restrictions", async () => {
    const source = "![first][photo]{width=320 height=200}\n![second][photo]\n\n[photo]: https://e.test/i.png"
    const main = parseMarkdownWithSourceMap(source)
    const rich = parseBlockContent(source, main)!
    const album = rich.blockContent.blocks[0]
    expect(album?.kind.oneofKind).toBe("album")
    const images = album?.kind.oneofKind === "album" ? album.kind.album.images : []
    expect(images.map((image) => slice(main.text, image.alt))).toEqual(["first", "second"])
    expect(images[0]?.state.oneofKind === "pending" ? images[0].state.pending.dimensions : undefined).toEqual({ width: 320, height: 200 })
    expect(rich.imageSources).toEqual([{ path: [0, 0], url: "https://e.test/i.png" }, { path: [0, 1], url: "https://e.test/i.png" }])
    const outgoing = await processOutgoingText({ text: source, parseMarkdown: true, entities: undefined })
    expect(outgoing.blockImageSources).toEqual(rich.imageSources)
    for (const url of ["javascript:alert(1)", "file:///tmp/a.png", "https://user:pass@e.test/a.png"]) {
      const rejected = parseBlockContent(`![image][id]\n\n[id]: ${url}`)!
      expect(rejected.imageSources).toEqual([])
      const image = rejected.blockContent.blocks[0]
      expect(image?.kind.oneofKind === "image" ? image.kind.image.state.oneofKind : undefined).toBe("unavailable")
    }
  })

  test("inline and reference image labels use the same escaped bracket boundary", () => {
    const source = String.raw`![a\](b)c](https://e.test/a.png)` + "\n" + String.raw`![d\]e][id]` + "\n\n[id]: https://e.test/b.png"
    const main = parseMarkdownWithSourceMap(source), rich = parseBlockContent(source, main)!
    const album = rich.blockContent.blocks[0]
    const images = album?.kind.oneofKind === "album" ? album.kind.album.images : []
    expect(images.map((image) => slice(main.text, image.alt))).toEqual(["a](b)c", "d]e"])
    expect(rich.imageSources.map((image) => image.url)).toEqual(["https://e.test/a.png", "https://e.test/b.png"])
  })

  test("definitions outside disclosures and display math still resolve images in each region", () => {
    const source = "<details>\n<summary>[title][id]</summary>\n![inside][id]\n</details>\n$$x$$\n![after][id]\n\n[id]: https://e.test/i.png"
    const main = parseMarkdownWithSourceMap(source)
    const rich = parseBlockContent(source, main)!
    expect(rich.blockContent.blocks.map((block) => block.kind.oneofKind)).toEqual(["disclosure", "math", "image"])
    expect(rich.imageSources).toEqual([{ path: [0, 0], url: "https://e.test/i.png" }, { path: [2], url: "https://e.test/i.png" }])
    expect(() => validateBlockContent(main.text, rich.blockContent)).not.toThrow()
  })

  test("a closing disclosure tag inside TeX cannot move later references outside the disclosure", () => {
    const source = "<details>\n<summary>Result</summary>\n$$\n</details>\n$$\n![inside][id]\n</details>\n\n[id]: https://e.test/i.png"
    const main = parseMarkdownWithSourceMap(source), rich = parseBlockContent(source, main)!
    expect(rich.blockContent.blocks.map((block) => block.kind.oneofKind)).toEqual(["disclosure"])
    const disclosure = rich.blockContent.blocks[0]
    expect(disclosure?.kind.oneofKind === "disclosure" ? disclosure.kind.disclosure.children.map((block) => block.kind.oneofKind) : [])
      .toEqual(["math", "image"])
    expect(rich.imageSources).toEqual([{ path: [0, 1], url: "https://e.test/i.png" }])
  })

  test("tables keep one TeX cell and links, reject image cells, and never schedule images inside TeX", () => {
    const source = "| Value |\n| --- |\n| $x|y$ [doc][id] $a|![fake][id]$ |\n\n[id]: https://e.test/i.png"
    const main = parseMarkdownWithSourceMap(source), rich = parseBlockContent(source, main)!
    expect(rich.imageSources).toEqual([])
    expect(rich.warnings).toBeUndefined()
    expect(urls(main.entities)).toEqual(["https://e.test/i.png"])
    const table = rich.blockContent.blocks[0]
    const rows = table?.kind.oneofKind === "table" ? table.kind.table.rows : []
    expect(rows.map((row) => row.cells.length)).toEqual([1, 1])
    expect(slice(main.text, rows[1]?.cells[0])).toBe("x|y doc a|![fake][id]")
    const rejected = parseBlockContent("| Value |\n| --- |\n| ![photo][id] |\n\n[id]: https://e.test/i.png")!
    expect(rejected.warnings).toEqual(["unsupported_table_content"])
    expect(rejected.imageSources).toEqual([])
  })

  test("Agent transport and explicit source entities preserve identity and UTF-16 ranges", () => {
    const source = "😀 [Maya][agent] and Max\n\n[agent]: inline://user?id=42&agent_id=9"
    const translated = fromMd(source)
    expect(translated.entities.entities.find((entity) => entity.type === MessageEntity_Type.MENTION)?.entity)
      .toEqual({ oneofKind: "mention", mention: { userId: 42n, agentId: 9n } })
    expect(fromMd(toMd(translated.text, translated.entities))).toEqual(translated)
    const explicit: MessageEntity = { type: MessageEntity_Type.MENTION, offset: BigInt(source.indexOf("Max")), length: 3n,
      entity: { oneofKind: "mention", mention: { userId: 8n, agentId: 7n } } }
    const result = processMessageText({ text: source, entities: { entities: [explicit] } })
    expect(result.entities?.entities.find((entity) => entity.type === MessageEntity_Type.MENTION))
      .toEqual({ ...explicit, offset: BigInt(result.text.indexOf("Max")) })
  })

  test("unresolved, escaped, invalid, and definition-only source stays readable", () => {
    for (const source of ["[label][missing]", "\\[label][missing]", "[id]:", "[id]: https://e.test", "> [id]: https://e.test", "- [id]: https://e.test"]) {
      expect(parseMarkdown(source).text).toBe(source.replace("\\[", "["))
      expect(fromMd(source).text).toBe(source.replace("\\[", "["))
      expect(urls(parseMarkdown(source).entities)).toEqual([])
    }
  })

  test("empty reference destinations stay noninteractive and native literal mode is unchanged", async () => {
    const empty = "[label][id]\n\n[id]: <>"
    expect(parseMarkdown(empty)).toEqual({ text: "label\n\n", entities: [] })
    expect(fromMd(empty)).toEqual({ text: "label\n\n", entities: { entities: [] } })
    const source = "![image][id]\n\n[id]: https://e.test/i.png"
    const literal = await processOutgoingText({ text: source, parseMarkdown: false, entities: undefined })
    expect(literal.text).toBe(source)
    expect(literal.blockContent).toBeUndefined()
    expect(literal.blockImageSources).toBeUndefined()
  })

  test("every streaming prefix and definition rewrite is valid and the final snapshot resolves once", () => {
    const source = "**[label][id]**\n\n![photo][id]\n\n[id]: <https://e.test/i.png> \"title\""
    for (let end = 0; end <= source.length; end++) {
      const snapshot = source.slice(0, end), main = parseMarkdownWithSourceMap(snapshot)
      const rich = parseBlockContent(snapshot, main)
      if (rich) expect(() => validateBlockContent(main.text, rich.blockContent)).not.toThrow()
      for (const entity of main.entities) expect(entity.offset >= 0n && entity.offset + entity.length <= BigInt(main.text.length)).toBe(true)
    }
    expect(urls(parseMarkdown(source).entities)).toEqual(["https://e.test/i.png", "https://e.test/i.png"])
    expect(urls(parseMarkdown(source.replace("e.test/i.png", "other.test/new.png")).entities))
      .toEqual(["https://other.test/new.png", "https://other.test/new.png"])
  })
})
