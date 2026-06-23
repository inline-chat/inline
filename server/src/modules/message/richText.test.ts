import { describe, expect, test } from "bun:test"
import {
  MessageEntity_Type,
  RichDirection,
  RichHorizontalAlign,
  RichTextStyle,
  RichVerticalAlign,
  type RichBlock,
  type RichMediaRef,
  type RichMessage,
  type RichText,
} from "@inline-chat/protocol/core"
import {
  RichTextValidationError,
  entitiesFromRichMessage,
  needsRichBlocks,
  normalizeRichMessage,
  parseRichMarkdown,
  renderRichMessage,
  richMediaDependencies,
} from "./richText"

const firstBlock = (message: RichMessage) => message.blocks[0]!
const kind = (block: RichBlock) => block.block.oneofKind
const firstText = (block: RichBlock): string => {
  switch (block.block.oneofKind) {
    case "paragraph":
      return flatten(block.block.paragraph.text)
    case "heading":
      return flatten(block.block.heading.text)
    case "code":
      return block.block.code.text
    case "details":
      return flatten(block.block.details.title)
    default:
      return ""
  }
}
const flatten = (nodes: RichText[]): string => nodes.map((node) => node.text + flatten(node.children)).join("")
const richMediaRef = (
  media: RichMediaRef["media"],
  alt = "media",
): RichMediaRef => ({
  alt,
  media,
})
const paragraphBlockForTest = (value: string): RichBlock => ({
  blockId: "",
  block: {
    oneofKind: "paragraph",
    paragraph: { text: [{ text: value, children: [], styles: [] }] },
  },
})

describe("parseRichMarkdown blocks", () => {
  test("parses a paragraph", () => {
    const rich = parseRichMarkdown("hello world")
    expect(kind(firstBlock(rich))).toBe("paragraph")
    expect(firstText(firstBlock(rich))).toBe("hello world")
    expect(rich.fallbackText).toBe("hello world")
  })

  test("parses blank-line separated paragraphs", () => {
    const rich = parseRichMarkdown("one\n\ntwo")
    expect(rich.blocks.map(kind)).toEqual(["paragraph", "paragraph"])
    expect(rich.fallbackText).toBe("one\n\ntwo")
  })

  test("does not require rich blocks for paragraph-only flat entity content", () => {
    const rich = parseRichMarkdown("Ship **bold**, <u>under</u>, ~~struck~~, `code`, and [docs](https://example.com)")

    expect(rich.blocks.map(kind)).toEqual(["paragraph"])
    expect(needsRichBlocks(rich, { ignoreParagraphDirection: true })).toBe(false)
    expect(entitiesFromRichMessage(rich)?.entities.map((entity) => entity.type)).toEqual(
      expect.arrayContaining([
        MessageEntity_Type.BOLD,
        MessageEntity_Type.UNDERLINE,
        MessageEntity_Type.STRIKETHROUGH,
        MessageEntity_Type.CODE,
        MessageEntity_Type.TEXT_URL,
      ]),
    )
  })

  test("requires rich blocks for spoiler paragraphs", () => {
    const rich = parseRichMarkdown("Reveal ||secret|| later")

    expect(rich.blocks.map(kind)).toEqual(["paragraph"])
    expect(needsRichBlocks(rich)).toBe(true)
  })

  for (let level = 1; level <= 6; level += 1) {
    test(`parses heading level ${level}`, () => {
      const rich = parseRichMarkdown(`${"#".repeat(level)} Heading ${level}`)
      const block = firstBlock(rich)
      expect(kind(block)).toBe("heading")
      expect(block.block.oneofKind === "heading" ? block.block.heading.level : 0).toBe(level)
      expect(rich.fallbackText).toBe(`Heading ${level}`)
      expect(entitiesFromRichMessage(rich)?.entities[0]?.type).toBe(MessageEntity_Type.BOLD)
    })
  }

  for (const marker of ["---", "***", "___", "------", "*****"]) {
    test(`parses divider ${marker}`, () => {
      const rich = parseRichMarkdown(marker)
      expect(kind(firstBlock(rich))).toBe("divider")
      expect(rich.fallbackText).toBe("---")
    })
  }

  for (const marker of ["-", "*", "+"]) {
    for (let count = 1; count <= 25; count += 1) {
      test(`parses unordered ${marker} list with ${count} items`, () => {
        const input = Array.from({ length: count }, (_, index) => `${marker} item ${index + 1}`).join("\n")
        const rich = parseRichMarkdown(input)
        const block = firstBlock(rich)
        expect(kind(block)).toBe("list")
        expect(block.block.oneofKind === "list" ? block.block.list.ordered : true).toBe(false)
        expect(block.block.oneofKind === "list" ? block.block.list.items : []).toHaveLength(count)
        expect(rich.fallbackText).toContain("- item 1")
      })
    }
  }

  for (let start = 1; start <= 30; start += 1) {
    test(`parses ordered list starting at ${start}`, () => {
      const rich = parseRichMarkdown(`${start}. first\n${start + 1}. second`)
      const block = firstBlock(rich)
      expect(kind(block)).toBe("list")
      expect(block.block.oneofKind === "list" ? block.block.list.ordered : false).toBe(true)
      expect(block.block.oneofKind === "list" ? block.block.list.start : 0).toBe(start)
      expect(rich.fallbackText).toBe(`${start}. first\n${start + 1}. second`)
    })
  }

  test("parses unordered task list item checked states", () => {
    const rich = parseRichMarkdown("- [ ] todo\n- [x] done\n- [X] shipped\n- plain")
    const block = firstBlock(rich)

    expect(kind(block)).toBe("list")
    expect(block.block.oneofKind === "list" ? block.block.list.items.map((item) => item.checked) : []).toEqual([
      false,
      true,
      true,
      undefined,
    ])
    expect(rich.fallbackText).toBe("- [ ] todo\n- [x] done\n- [x] shipped\n- plain")
  })

  test("parses ordered task list item checked states", () => {
    const rich = parseRichMarkdown("3. [ ] write spec\n4. [x] ship")
    const block = firstBlock(rich)

    expect(kind(block)).toBe("list")
    expect(block.block.oneofKind === "list" ? block.block.list.ordered : false).toBe(true)
    expect(block.block.oneofKind === "list" ? block.block.list.items.map((item) => item.checked) : []).toEqual([false, true])
    expect(rich.fallbackText).toBe("3. [ ] write spec\n4. [x] ship")
  })

  for (let lineCount = 1; lineCount <= 40; lineCount += 1) {
    test(`parses quote with ${lineCount} lines`, () => {
      const input = Array.from({ length: lineCount }, (_, index) => `> quoted ${index + 1}`).join("\n")
      const rich = parseRichMarkdown(input)
      expect(kind(firstBlock(rich))).toBe("quote")
      expect(rich.fallbackText).toContain("quoted 1")
      expect(rich.fallbackText).not.toContain(">")
      const quote = entitiesFromRichMessage(rich)?.entities.find((entity) => entity.type === MessageEntity_Type.BLOCKQUOTE)
      expect(quote?.offset).toBe(0n)
      expect(quote?.length).toBe(BigInt(rich.fallbackText.length))
    })
  }

  for (const fence of ["```", "~~~"]) {
    for (const language of ["", "ts", "swift", "objective-c", "c++", "python"]) {
      test(`parses ${fence} code block language ${language || "empty"}`, () => {
        const rich = parseRichMarkdown(`${fence}${language}\nlet x = 1\n${fence}`)
        const block = firstBlock(rich)
        expect(kind(block)).toBe("code")
        expect(block.block.oneofKind === "code" ? block.block.code.language : undefined).toBe(
          language ? language.replace(/[^\w.+-]/g, "") : undefined,
        )
        expect(block.direction).toBe(RichDirection.DIRECTION_LTR)
        expect(rich.fallbackText).toBe("let x = 1")
        expect(entitiesFromRichMessage(rich)?.entities[0]?.type).toBe(MessageEntity_Type.PRE)
      })
    }
  }
})

describe("parseRichMarkdown rich blocks", () => {
  for (let index = 1; index <= 30; index += 1) {
    test(`parses details block ${index}`, () => {
      const rich = parseRichMarkdown(`<details open>\n<summary>Why ${index}</summary>\nBody ${index}\n</details>`)
      const block = firstBlock(rich)
      expect(kind(block)).toBe("details")
      expect(block.block.oneofKind === "details" ? flatten(block.block.details.title) : "").toBe(`Why ${index}`)
      expect(block.block.oneofKind === "details" ? block.block.details.initiallyOpen : false).toBe(true)
      expect(rich.fallbackText).toBe(`Why ${index}\nBody ${index}`)
    })
  }

  for (let index = 1; index <= 25; index += 1) {
    test(`parses expandable blockquote ${index}`, () => {
      const rich = parseRichMarkdown(`<blockquote expandable>\nVisible ${index}\nHidden ${index}\n</blockquote>`)
      const block = firstBlock(rich)
      expect(kind(block)).toBe("quote")
      expect(block.block.oneofKind === "quote" ? block.block.quote.expandable : false).toBe(true)
      expect(block.block.oneofKind === "quote" ? block.block.quote.initiallyCollapsed : false).toBe(true)
      expect(rich.fallbackText).toBe(`Visible ${index}\nHidden ${index}`)
      const quote = entitiesFromRichMessage(rich)?.entities.find(
        (entity) => entity.type === MessageEntity_Type.EXPANDABLE_BLOCKQUOTE,
      )
      expect(quote?.offset).toBe(0n)
      expect(quote?.length).toBe(BigInt(rich.fallbackText.length))
    })
  }

  for (let index = 1; index <= 30; index += 1) {
    test(`parses table ${index}`, () => {
      const rich = parseRichMarkdown(`| Left ${index} | Right |\n| :--- | ---: |\n| A | B |`)
      const block = firstBlock(rich)
      expect(kind(block)).toBe("table")
      const table = block.block.oneofKind === "table" ? block.block.table : undefined
      expect(table?.rows).toHaveLength(2)
      expect(table?.rows[0]?.cells[0]?.header).toBe(true)
      expect(table?.rows[0]?.cells[0]?.align).toBe(RichHorizontalAlign.HORIZONTAL_ALIGN_LEFT)
      expect(table?.rows[0]?.cells[1]?.align).toBe(RichHorizontalAlign.HORIZONTAL_ALIGN_RIGHT)
      expect(rich.fallbackText).toBe(`Left ${index} | Right\nA | B`)
    })
  }

  for (let index = 1; index <= 30; index += 1) {
    test(`parses display math ${index}`, () => {
      const rich = parseRichMarkdown(`$$\nx_${index} = y^2\n$$`)
      const block = firstBlock(rich)
      expect(kind(block)).toBe("math")
      expect(block.block.oneofKind === "math" ? block.block.math.source : "").toBe(`x_${index} = y^2`)
      expect(rich.fallbackText).toBe(`x_${index} = y^2`)
    })
  }

  for (let index = 1; index <= 25; index += 1) {
    test(`parses image public URL block ${index}`, () => {
      const rich = parseRichMarkdown(`![Chart ${index}](https://example.com/chart-${index}.png)`)
      const block = firstBlock(rich)
      expect(kind(block)).toBe("photo")
      expect(block.block.oneofKind === "photo" ? block.block.photo.media?.media.oneofKind : undefined).toBe("publicUrl")
      expect(richMediaDependencies(rich)[0]?.kind).toBe("public_url")
      expect(rich.fallbackText).toBe(`[Image: Chart ${index}] Chart ${index}`)
    })
  }

  test("parses image public URL blocks with parentheses in the URL", () => {
    const url = "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1f/Cockatiel_(Nymphicus_hollandicus).jpg/800px-Cockatiel_(Nymphicus_hollandicus).jpg"
    const rich = parseRichMarkdown(`![Cockatiel](${url})`)
    const block = firstBlock(rich)

    expect(kind(block)).toBe("photo")
    expect(block.block.oneofKind === "photo" ? block.block.photo.media?.media : undefined).toEqual({
      oneofKind: "publicUrl",
      publicUrl: url,
    })
    expect(rich.fallbackText).toBe("[Image: Cockatiel] Cockatiel")
  })

  test("does not parse non-HTTPS markdown image URLs as rich media", () => {
    const rich = parseRichMarkdown("![Chart](http://example.com/chart.png)")

    expect(kind(firstBlock(rich))).toBe("paragraph")
    expect(richMediaDependencies(rich)).toEqual([])
    expect(rich.fallbackText).toBe("![Chart](http://example.com/chart.png)")
  })

  test("indexes structured audio blocks as voice dependencies", () => {
    const rich = normalizeRichMessage({
      blocks: [
        {
          blockId: "voice-block",
          block: {
            oneofKind: "audio",
            audio: {
              media: {
                alt: "Voice note",
                media: { oneofKind: "voiceId", voiceId: 42n },
              },
              caption: [{ text: "voice caption", children: [], styles: [] }],
              duration: 9,
            },
          },
        },
      ],
      fallbackText: "Voice note",
      version: 4,
    })

    expect(richMediaDependencies(rich)).toMatchObject([
      {
        blockId: "voice-block",
        blockPath: "0",
        kind: "voice",
      },
    ])
  })

  test("indexes every current rich media-bearing block shape in document order", () => {
    const rich = normalizeRichMessage({
      blocks: [
        {
          blockId: "photo",
          block: {
            oneofKind: "photo",
            photo: { media: richMediaRef({ oneofKind: "photoId", photoId: 1n }, "photo"), caption: [] },
          },
        },
        {
          blockId: "video",
          block: {
            oneofKind: "video",
            video: { media: richMediaRef({ oneofKind: "videoId", videoId: 2n }, "video"), caption: [] },
          },
        },
        {
          blockId: "document",
          block: {
            oneofKind: "document",
            document: { media: richMediaRef({ oneofKind: "documentId", documentId: 3n }, "document"), caption: [] },
          },
        },
        {
          blockId: "audio",
          block: {
            oneofKind: "audio",
            audio: { media: richMediaRef({ oneofKind: "voiceId", voiceId: 4n }, "voice"), caption: [] },
          },
        },
        {
          blockId: "embed",
          block: {
            oneofKind: "embed",
            embed: {
              url: "https://example.com/embed",
              poster: richMediaRef({ oneofKind: "publicUrl", publicUrl: "https://example.com/poster.jpg" }, "poster"),
              caption: [],
              fullWidth: false,
              allowScrolling: false,
            },
          },
        },
        {
          blockId: "post",
          block: {
            oneofKind: "embedPost",
            embedPost: {
              url: "https://example.com/post",
              author: "Author",
              authorPhoto: richMediaRef({ oneofKind: "photoId", photoId: 5n }, "author"),
              blocks: [
                {
                  blockId: "post-photo",
                  block: {
                    oneofKind: "photo",
                    photo: { media: richMediaRef({ oneofKind: "photoId", photoId: 6n }, "post photo"), caption: [] },
                  },
                },
              ],
              caption: [],
            },
          },
        },
        {
          blockId: "preview",
          block: {
            oneofKind: "linkPreview",
            linkPreview: {
              url: "https://example.com",
              media: richMediaRef({ oneofKind: "photoId", photoId: 7n }, "preview"),
              compact: false,
            },
          },
        },
        {
          blockId: "collage",
          block: {
            oneofKind: "collage",
            collage: {
              items: [
                {
                  blockId: "collage-photo",
                  block: {
                    oneofKind: "photo",
                    photo: { media: richMediaRef({ oneofKind: "photoId", photoId: 8n }, "collage photo"), caption: [] },
                  },
                },
                {
                  blockId: "collage-document",
                  block: {
                    oneofKind: "document",
                    document: { media: richMediaRef({ oneofKind: "documentId", documentId: 9n }, "collage doc"), caption: [] },
                  },
                },
              ],
              caption: [],
            },
          },
        },
      ],
      fallbackText: "",
      version: 1,
    })

    expect(richMediaDependencies(rich).map(({ blockId, blockPath, kind, ref }) => ({
      blockId,
      blockPath,
      kind,
      refKind: ref.media.oneofKind,
    }))).toEqual([
      { blockId: "photo", blockPath: "0", kind: "photo", refKind: "photoId" },
      { blockId: "video", blockPath: "1", kind: "video", refKind: "videoId" },
      { blockId: "document", blockPath: "2", kind: "document", refKind: "documentId" },
      { blockId: "audio", blockPath: "3", kind: "voice", refKind: "voiceId" },
      { blockId: "embed", blockPath: "4", kind: "public_url", refKind: "publicUrl" },
      { blockId: "post", blockPath: "5", kind: "photo", refKind: "photoId" },
      { blockId: "post-photo", blockPath: "5.0", kind: "photo", refKind: "photoId" },
      { blockId: "preview", blockPath: "6", kind: "photo", refKind: "photoId" },
      { blockId: "collage-photo", blockPath: "7.0", kind: "photo", refKind: "photoId" },
      { blockId: "collage-document", blockPath: "7.1", kind: "document", refKind: "documentId" },
    ])
  })
})

describe("parseRichMarkdown inline spans", () => {
  const styleCases = [
    { name: "bold-star", markdown: "**value**", style: RichTextStyle.STYLE_BOLD, entity: MessageEntity_Type.BOLD },
    { name: "bold-underscore", markdown: "__value__", style: RichTextStyle.STYLE_BOLD, entity: MessageEntity_Type.BOLD },
    { name: "italic-star", markdown: "*value*", style: RichTextStyle.STYLE_ITALIC, entity: MessageEntity_Type.ITALIC },
    { name: "italic-underscore", markdown: "_value_", style: RichTextStyle.STYLE_ITALIC, entity: MessageEntity_Type.ITALIC },
    { name: "code", markdown: "`value`", style: RichTextStyle.STYLE_CODE, entity: MessageEntity_Type.CODE },
    {
      name: "strike",
      markdown: "~~value~~",
      style: RichTextStyle.STYLE_STRIKETHROUGH,
      entity: MessageEntity_Type.STRIKETHROUGH,
    },
    {
      name: "underline",
      markdown: "<u>value</u>",
      style: RichTextStyle.STYLE_UNDERLINE,
      entity: MessageEntity_Type.UNDERLINE,
    },
    {
      name: "spoiler",
      markdown: "||value||",
      style: RichTextStyle.STYLE_SPOILER,
      entity: undefined,
    },
  ] as const

  for (const item of styleCases) {
    for (let index = 1; index <= 20; index += 1) {
      test(`parses inline ${item.name} case ${index}`, () => {
        const rich = parseRichMarkdown(`before ${item.markdown} after ${index}`)
        const block = firstBlock(rich)
        const node = block.block.oneofKind === "paragraph"
          ? block.block.paragraph.text.find((candidate) => candidate.text === "value")
          : undefined
        expect(node?.styles).toContain(item.style)
        expect(rich.fallbackText).toBe(`before value after ${index}`)
        if (item.entity !== undefined) {
          expect(entitiesFromRichMessage(rich)?.entities.some((entity) => entity.type === item.entity)).toBe(true)
        }
      })
    }
  }

  for (let index = 1; index <= 60; index += 1) {
    test(`parses markdown link ${index}`, () => {
      const url = `https://example.com/path/${index}?q=a(b)`
      const rich = parseRichMarkdown(`open [Example ${index}](${url}) now`)
      const block = firstBlock(rich)
      const link = block.block.oneofKind === "paragraph" ? block.block.paragraph.text.find((node) => node.url) : undefined
      expect(link?.url).toBe(url)
      expect(rich.fallbackText).toBe(`open Example ${index} now`)
      const entity = entitiesFromRichMessage(rich)?.entities.find((candidate) => candidate.type === MessageEntity_Type.TEXT_URL)
      expect(entity?.entity.oneofKind).toBe("textUrl")
    })
  }

  test("parses angle-wrapped markdown links with parentheses in the URL", () => {
    const url = "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1f/Cockatiel_(Nymphicus_hollandicus).jpg/800px-Cockatiel_(Nymphicus_hollandicus).jpg"
    const rich = parseRichMarkdown(`Source: [Cockatiel](<${url}>)`)
    const entity = entitiesFromRichMessage(rich)?.entities.find((candidate) => candidate.type === MessageEntity_Type.TEXT_URL)

    expect(rich.fallbackText).toBe("Source: Cockatiel")
    expect(entity?.entity.oneofKind).toBe("textUrl")
    expect(entity?.entity.oneofKind === "textUrl" ? entity.entity.textUrl.url : undefined).toBe(url)
  })

  for (let index = 1; index <= 30; index += 1) {
    test(`parses nested bold link ${index}`, () => {
      const rich = parseRichMarkdown(`[**label ${index}**](https://example.com/${index})`)
      const entityTypes = entitiesFromRichMessage(rich)?.entities.map((entity) => entity.type) ?? []
      expect(entityTypes).toContain(MessageEntity_Type.BOLD)
      expect(entityTypes).toContain(MessageEntity_Type.TEXT_URL)
      expect(rich.fallbackText).toBe(`label ${index}`)
    })
  }

  for (let index = 1; index <= 25; index += 1) {
    test(`keeps malformed link as fallback text ${index}`, () => {
      const input = `broken [label ${index}](https://example.com`
      const rich = parseRichMarkdown(input)
      expect(rich.fallbackText).toBe(input)
      expect(entitiesFromRichMessage(rich)).toBeUndefined()
    })
  }
})

describe("parseRichMarkdown direction, ids, and normalization", () => {
  for (const [text, direction] of [
    ["hello", RichDirection.DIRECTION_LTR],
    ["سلام", RichDirection.DIRECTION_RTL],
    ["123 hello", RichDirection.DIRECTION_LTR],
    ["123 سلام", RichDirection.DIRECTION_RTL],
  ] as const) {
    test(`infers direction for ${text}`, () => {
      const rich = parseRichMarkdown(text)
      expect(firstBlock(rich).direction).toBe(direction)
    })
  }

  for (let index = 1; index <= 30; index += 1) {
    test(`normalizes explicit rich message ${index}`, () => {
      const rich = normalizeRichMessage({
        blocks: [
          {
            blockId: "",
            block: {
              oneofKind: "heading",
              heading: {
                text: [{ text: `Title ${index}`, children: [], styles: [RichTextStyle.STYLE_BOLD] }],
                level: 99,
              },
            },
          },
          {
            blockId: "",
            block: {
              oneofKind: "thinking",
              thinking: {
                blocks: [{ blockId: "", block: { oneofKind: "paragraph", paragraph: { text: [{ text: "private", children: [], styles: [] }] } } }],
                initiallyCollapsed: true,
              },
            },
          },
        ],
        direction: RichDirection.DIRECTION_AUTO,
        fallbackText: "",
        version: 1,
      })

      expect(rich.blocks).toHaveLength(1)
      expect(rich.blocks[0]?.blockId).toMatch(/^b_0_heading_/)
      expect(rich.blocks[0]?.block.oneofKind === "heading" ? rich.blocks[0]?.block.heading.level : 0).toBe(6)
      expect(rich.fallbackText).toBe(`Title ${index}`)
    })
  }

  test("keeps thinking blocks when explicitly allowed", () => {
    const rich = normalizeRichMessage(
      {
        blocks: [
          {
            blockId: "thinking",
            block: {
              oneofKind: "thinking",
              thinking: {
                blocks: [{ blockId: "", block: { oneofKind: "paragraph", paragraph: { text: [{ text: "private", children: [], styles: [] }] } } }],
                initiallyCollapsed: true,
              },
            },
          },
        ],
        direction: RichDirection.DIRECTION_AUTO,
        fallbackText: "",
        version: 1,
      },
      { allowThinking: true },
    )

    expect(rich.blocks).toHaveLength(1)
    expect(kind(firstBlock(rich))).toBe("thinking")
    expect(rich.fallbackText).toBe("")
  })

  test("does not preserve supplied fallback when final thinking blocks are stripped", () => {
    const rich = normalizeRichMessage({
      blocks: [
        {
          blockId: "thinking",
          block: {
            oneofKind: "thinking",
            thinking: {
              blocks: [
                {
                  blockId: "",
                  block: {
                    oneofKind: "paragraph",
                    paragraph: { text: [{ text: "private reasoning", children: [], styles: [] }] },
                  },
                },
              ],
              initiallyCollapsed: true,
            },
          },
        },
      ],
      direction: RichDirection.DIRECTION_AUTO,
      fallbackText: "private reasoning",
      version: 1,
    })

    expect(rich.blocks).toHaveLength(0)
    expect(rich.fallbackText).toBe("")
  })

  test("normalizes table colspan and rowspan spans for structured rich messages", () => {
    const rich = normalizeRichMessage({
      blocks: [
        {
          blockId: "table",
          block: {
            oneofKind: "table",
            table: {
              rows: [
                {
                  cells: [
                    {
                      text: [{ text: "Area", children: [], styles: [] }],
                      header: true,
                      colspan: 0,
                      rowspan: 99,
                      align: RichHorizontalAlign.HORIZONTAL_ALIGN_RIGHT,
                      valign: RichVerticalAlign.VERTICAL_ALIGN_BOTTOM,
                    },
                    {
                      text: [{ text: "Phase", children: [], styles: [] }],
                      header: true,
                      colspan: 2,
                      rowspan: 1,
                    },
                  ],
                },
                {
                  cells: [
                    {
                      text: [{ text: "Render", children: [], styles: [] }],
                      header: false,
                      colspan: 99,
                      rowspan: -10,
                    },
                  ],
                },
              ],
              caption: [{ text: "Caption", children: [], styles: [] }],
              bordered: true,
              striped: true,
            },
          },
        },
      ],
      direction: RichDirection.DIRECTION_LTR,
      fallbackText: "",
      version: 1,
    })

    const block = firstBlock(rich)
    expect(kind(block)).toBe("table")
    const table = block.block.oneofKind === "table" ? block.block.table : undefined
    expect(table?.rows[0]?.cells[0]?.colspan).toBe(1)
    expect(table?.rows[0]?.cells[0]?.rowspan).toBe(2)
    expect(table?.rows[0]?.cells[0]?.align).toBe(RichHorizontalAlign.HORIZONTAL_ALIGN_RIGHT)
    expect(table?.rows[0]?.cells[0]?.valign).toBe(RichVerticalAlign.VERTICAL_ALIGN_BOTTOM)
    expect(table?.rows[0]?.cells[1]?.colspan).toBe(2)
    expect(table?.rows[1]?.cells[0]?.colspan).toBe(20)
    expect(table?.rows[1]?.cells[0]?.rowspan).toBe(1)
    expect(rich.fallbackText).toBe("Area | Phase\nRender")
  })

  test("normalizes structured rich text node newlines before fallback and entity rendering", () => {
    const rich = normalizeRichMessage({
      blocks: [
        {
          blockId: "p",
          block: {
            oneofKind: "paragraph",
            paragraph: {
              text: [
                {
                  text: "one\r\ntwo\rthree ",
                  children: [
                    {
                      text: "child\r\nlink",
                      children: [],
                      styles: [],
                      url: "https://example.com/child",
                    },
                  ],
                  styles: [RichTextStyle.STYLE_BOLD],
                },
              ],
            },
          },
        },
      ],
      direction: RichDirection.DIRECTION_AUTO,
      fallbackText: "",
      version: 1,
    })

    const rendered = renderRichMessage(rich)
    const block = firstBlock(rich)
    const node = block.block.oneofKind === "paragraph" ? block.block.paragraph.text[0] : undefined
    const child = node?.children[0]
    const link = rendered.entities?.entities.find((entity) => entity.type === MessageEntity_Type.TEXT_URL)

    expect(node?.text).toBe("one\ntwo\nthree ")
    expect(child?.text).toBe("child\nlink")
    expect(rich.fallbackText).toBe("one\ntwo\nthree child\nlink")
    expect(rendered.text).toBe("one\ntwo\nthree child\nlink")
    expect(link?.offset).toBe(14n)
    expect(link?.length).toBe(10n)
  })

  test("generates deterministic fallback text for the full durable block suite", () => {
    const text = (value: string): RichText[] => [{ text: value, children: [], styles: [] }]
    const paragraph = (value: string): RichBlock => ({
      blockId: "",
      block: {
        oneofKind: "paragraph",
        paragraph: { text: text(value) },
      },
    })

    const rich = normalizeRichMessage({
      blocks: [
        {
          blockId: "",
          block: {
            oneofKind: "heading",
            heading: { text: text("Report"), level: 2 },
          },
        },
        {
          blockId: "",
          block: {
            oneofKind: "paragraph",
            paragraph: {
              text: [
                { text: "Open ", children: [], styles: [] },
                { text: "docs", children: [], styles: [RichTextStyle.STYLE_BOLD], url: "https://example.com/docs" },
              ],
            },
          },
        },
        {
          blockId: "",
          block: {
            oneofKind: "details",
            details: { title: text("More"), blocks: [paragraph("Nested detail")], initiallyOpen: false },
          },
        },
        {
          blockId: "",
          block: {
            oneofKind: "quote",
            quote: { blocks: [paragraph("Quoted text")], expandable: true, initiallyCollapsed: true },
          },
        },
        {
          blockId: "",
          block: {
            oneofKind: "list",
            list: {
              ordered: true,
              start: 2,
              items: [
                { blocks: [paragraph("Todo")], checked: false },
                { blocks: [paragraph("Done")], checked: true },
              ],
            },
          },
        },
        {
          blockId: "",
          block: { oneofKind: "code", code: { text: "let x = 1", language: "swift" } },
        },
        { blockId: "", block: { oneofKind: "divider", divider: {} } },
        {
          blockId: "",
          block: {
            oneofKind: "photo",
            photo: { media: { alt: "Chart", media: { oneofKind: "photoId", photoId: 1n } }, caption: text("Q1") },
          },
        },
        {
          blockId: "",
          block: {
            oneofKind: "video",
            video: { media: { alt: "Demo", media: { oneofKind: "videoId", videoId: 2n } }, caption: text("clip") },
          },
        },
        {
          blockId: "",
          block: {
            oneofKind: "document",
            document: { media: { alt: "Spec", media: { oneofKind: "documentId", documentId: 3n } }, caption: text("pdf") },
          },
        },
        {
          blockId: "",
          block: {
            oneofKind: "audio",
            audio: { media: { alt: "Voice", media: { oneofKind: "voiceId", voiceId: 4n } }, caption: text("note") },
          },
        },
        {
          blockId: "",
          block: {
            oneofKind: "table",
            table: {
              rows: [
                {
                  cells: [
                    { text: text("Area"), header: true, colspan: 1, rowspan: 1 },
                    { text: text("Phase"), header: true, colspan: 1, rowspan: 1 },
                  ],
                },
                {
                  cells: [
                    { text: text("Mac"), header: false, colspan: 1, rowspan: 1 },
                    { text: text("Ready"), header: false, colspan: 1, rowspan: 1 },
                  ],
                },
              ],
              caption: text("ignored table caption"),
              bordered: true,
              striped: false,
            },
          },
        },
        {
          blockId: "",
          block: { oneofKind: "math", math: { source: "raw", display: true, fallback: "E=mc^2" } },
        },
        {
          blockId: "",
          block: {
            oneofKind: "map",
            map: { latitude: 10, longitude: 20, zoom: 12, title: "HQ", caption: text("location") },
          },
        },
        {
          blockId: "",
          block: {
            oneofKind: "embed",
            embed: { provider: "YouTube", caption: text("watch"), fullWidth: false, allowScrolling: false },
          },
        },
        {
          blockId: "",
          block: {
            oneofKind: "embedPost",
            embedPost: { url: "https://example.com/post", author: "Alice", blocks: [paragraph("Post body")], caption: [] },
          },
        },
        {
          blockId: "",
          block: {
            oneofKind: "linkPreview",
            linkPreview: { url: "https://example.com", title: "Preview title", compact: false },
          },
        },
        {
          blockId: "",
          block: {
            oneofKind: "collage",
            collage: {
              items: [
                {
                  blockId: "",
                  block: {
                    oneofKind: "photo",
                    photo: { media: { alt: "A", media: { oneofKind: "photoId", photoId: 5n } }, caption: [] },
                  },
                },
                {
                  blockId: "",
                  block: {
                    oneofKind: "photo",
                    photo: { media: { alt: "B", media: { oneofKind: "photoId", photoId: 6n } }, caption: [] },
                  },
                },
              ],
              caption: text("Gallery"),
            },
          },
        },
        {
          blockId: "",
          block: {
            oneofKind: "thinking",
            thinking: { blocks: [paragraph("private")], initiallyCollapsed: true },
          },
        },
      ],
      direction: RichDirection.DIRECTION_AUTO,
      fallbackText: "stale fallback must not win",
      version: 1,
    })

    expect(rich.fallbackText).toBe(
      [
        "Report",
        "Open docs",
        "More\nNested detail",
        "Quoted text",
        "2. [ ] Todo\n3. [x] Done",
        "let x = 1",
        "---",
        "[Image: Chart] Q1",
        "[Video: Demo] clip",
        "[Document: Spec] pdf",
        "[Audio: Voice] note",
        "Area | Phase\nMac | Ready",
        "E=mc^2",
        "HQ: location",
        "YouTube: watch",
        "Alice\nPost body",
        "Preview title",
        "Collage (2): Gallery",
      ].join("\n\n"),
    )
    expect(rich.blocks.map((block) => block.block.oneofKind)).not.toContain("thinking")
    expect(renderRichMessage(rich).text).toBe(rich.fallbackText)
  })

  test("rejects oversized fallback text", () => {
    expect(() => parseRichMarkdown("x".repeat(32_769))).toThrow(RichTextValidationError)
  })

  test("rejects oversized structured fallback generated from rich blocks", () => {
    expect(() =>
      normalizeRichMessage({
        blocks: [paragraphBlockForTest("x".repeat(32_769))],
        direction: RichDirection.DIRECTION_AUTO,
        fallbackText: "",
        version: 1,
      }),
    ).toThrow(RichTextValidationError)
  })

  test("rejects structured rich messages whose combined fallback exceeds the text limit", () => {
    expect(() =>
      normalizeRichMessage({
        blocks: [
          paragraphBlockForTest("x".repeat(32_767)),
          paragraphBlockForTest("y"),
        ],
        direction: RichDirection.DIRECTION_AUTO,
        fallbackText: "",
        version: 1,
      }),
    ).toThrow(RichTextValidationError)
  })

  test("applies the rich text length limit as UTF-16 code units", () => {
    const emoji = "🙂"

    expect(() => normalizeRichMessage({ blocks: [], fallbackText: emoji.repeat(16_384), version: 1 })).not.toThrow()
    expect(() => parseRichMarkdown(emoji.repeat(16_385))).toThrow(RichTextValidationError)
  })

  test("renders entity offsets as UTF-16 code units around surrogate pairs", () => {
    const rendered = renderRichMessage(parseRichMarkdown("🙂 [link](https://example.com)"))
    const entity = rendered.entities?.entities[0]

    expect(rendered.text).toBe("🙂 link")
    expect(entity?.type).toBe(MessageEntity_Type.TEXT_URL)
    expect(entity?.offset).toBe(3n)
    expect(entity?.length).toBe(4n)
  })

  test("keeps structured fallback whitespace aligned with generated entity offsets", () => {
    const rich = normalizeRichMessage({
      blocks: [
        {
          blockId: "p",
          block: {
            oneofKind: "paragraph",
            paragraph: {
              text: [
                { text: "  ", children: [], styles: [] },
                {
                  text: "link",
                  children: [],
                  styles: [RichTextStyle.STYLE_BOLD],
                  url: "https://example.com",
                },
                { text: "  ", children: [], styles: [] },
              ],
            },
          },
        },
      ],
      direction: RichDirection.DIRECTION_AUTO,
      fallbackText: "stale fallback",
      version: 1,
    })
    const rendered = renderRichMessage(rich)
    const entities = rendered.entities?.entities ?? []

    expect(rich.fallbackText).toBe("  link  ")
    expect(rendered.text).toBe("  link  ")
    expect(entities.map((entity) => ({
      type: entity.type,
      offset: entity.offset,
      length: entity.length,
    }))).toEqual([
      { type: MessageEntity_Type.BOLD, offset: 2n, length: 4n },
      { type: MessageEntity_Type.TEXT_URL, offset: 2n, length: 4n },
    ])
  })

  test("allows Telegram-compatible maximum media count", () => {
    const rich = normalizeRichMessage({
      blocks: Array.from({ length: 50 }, (_, index): RichBlock => ({
        blockId: "",
        block: {
          oneofKind: "photo",
          photo: {
            media: {
              alt: `Photo ${index + 1}`,
              media: { oneofKind: "photoId", photoId: BigInt(index + 1) },
            },
            caption: [],
          },
        },
      })),
      direction: RichDirection.DIRECTION_AUTO,
      fallbackText: "",
      version: 1,
    })

    expect(richMediaDependencies(rich)).toHaveLength(50)
  })

  test("rejects rich messages above Telegram-compatible media count", () => {
    expect(() =>
      normalizeRichMessage({
        blocks: Array.from({ length: 51 }, (_, index): RichBlock => ({
          blockId: "",
          block: {
            oneofKind: "photo",
            photo: {
              media: {
                alt: `Photo ${index + 1}`,
                media: { oneofKind: "photoId", photoId: BigInt(index + 1) },
              },
              caption: [],
            },
          },
        })),
        direction: RichDirection.DIRECTION_AUTO,
        fallbackText: "",
        version: 1,
      }),
    ).toThrow(RichTextValidationError)
  })

  test("rejects parsed rich markdown above the block limit instead of truncating fallback text", () => {
    const input = Array.from({ length: 501 }, (_, index) => `paragraph ${index + 1}`).join("\n\n")

    expect(() => parseRichMarkdown(input)).toThrow(RichTextValidationError)
  })

  test("rejects parsed rich markdown list items above the block limit", () => {
    const input = Array.from({ length: 501 }, (_, index) => `- item ${index + 1}`).join("\n")

    expect(() => parseRichMarkdown(input)).toThrow(RichTextValidationError)
  })

  test("rejects structured rich messages above the block limit instead of truncating", () => {
    expect(() =>
      normalizeRichMessage({
        blocks: Array.from({ length: 501 }, (_, index) => paragraphBlockForTest(`block ${index + 1}`)),
        direction: RichDirection.DIRECTION_AUTO,
        fallbackText: "",
        version: 1,
      }),
    ).toThrow(RichTextValidationError)
  })

  test("allows structured nested rich messages at the total block limit", () => {
    const rich = normalizeRichMessage({
      blocks: [
        {
          blockId: "details",
          block: {
            oneofKind: "details",
            details: {
              title: [{ text: "Budget", children: [], styles: [] }],
              blocks: Array.from({ length: 499 }, (_, index) => paragraphBlockForTest(`item ${index + 1}`)),
              initiallyOpen: true,
            },
          },
        },
      ],
      direction: RichDirection.DIRECTION_AUTO,
      fallbackText: "",
      version: 1,
    })

    const details = rich.blocks[0]?.block.oneofKind === "details" ? rich.blocks[0].block.details : undefined
    expect(details?.blocks).toHaveLength(499)
    expect(rich.fallbackText).toContain("Budget\nitem 1")
  })

  test("rejects structured nested rich messages above the total block limit", () => {
    const detailsBlock = (label: string): RichBlock => ({
      blockId: label,
      block: {
        oneofKind: "details",
        details: {
          title: [{ text: label, children: [], styles: [] }],
          blocks: Array.from({ length: 250 }, (_, index) => paragraphBlockForTest(`${label} ${index + 1}`)),
          initiallyOpen: true,
        },
      },
    })

    expect(() =>
      normalizeRichMessage({
        blocks: [detailsBlock("one"), detailsBlock("two")],
        direction: RichDirection.DIRECTION_AUTO,
        fallbackText: "",
        version: 1,
      }),
    ).toThrow(RichTextValidationError)
  })

  test("rejects oversized stripped thinking arrays before they can bypass the block limit", () => {
    expect(() =>
      normalizeRichMessage({
        blocks: Array.from({ length: 501 }, (_, index): RichBlock => ({
          blockId: `thinking-${index}`,
          block: {
            oneofKind: "thinking",
            thinking: {
              blocks: [paragraphBlockForTest(`private ${index}`)],
              initiallyCollapsed: true,
            },
          },
        })),
        direction: RichDirection.DIRECTION_AUTO,
        fallbackText: "",
        version: 1,
      }),
    ).toThrow(RichTextValidationError)
  })

  test("rejects structured rich list items above the block limit instead of truncating", () => {
    expect(() =>
      normalizeRichMessage({
        blocks: [
          {
            blockId: "",
            block: {
              oneofKind: "list",
              list: {
                ordered: false,
                start: 1,
                items: Array.from({ length: 501 }, (_, index) => ({
                  blocks: [paragraphBlockForTest(`item ${index + 1}`)],
                })),
              },
            },
          },
        ],
        direction: RichDirection.DIRECTION_AUTO,
        fallbackText: "",
        version: 1,
      }),
    ).toThrow(RichTextValidationError)
  })

  test("rejects structured rich text above the nesting depth limit instead of dropping content", () => {
    let text: RichText = { text: "leaf", children: [], styles: [] }
    for (let index = 0; index < 18; index += 1) {
      text = { text: "", children: [text], styles: [] }
    }

    expect(() =>
      normalizeRichMessage({
        blocks: [
          {
            blockId: "",
            block: {
              oneofKind: "paragraph",
              paragraph: { text: [text] },
            },
          },
        ],
        direction: RichDirection.DIRECTION_AUTO,
        fallbackText: "",
        version: 1,
      }),
    ).toThrow(RichTextValidationError)
  })

  for (let index = 1; index <= 30; index += 1) {
    test(`renders entity offsets ${index}`, () => {
      const rich = parseRichMarkdown(`A **bold ${index}** and \`code ${index}\``)
      const rendered = renderRichMessage(rich)
      const bold = rendered.entities?.entities.find((entity) => entity.type === MessageEntity_Type.BOLD)
      const code = rendered.entities?.entities.find((entity) => entity.type === MessageEntity_Type.CODE)

      expect(rendered.text.slice(Number(bold!.offset), Number(bold!.offset + bold!.length))).toBe(`bold ${index}`)
      expect(rendered.text.slice(Number(code!.offset), Number(code!.offset + code!.length))).toBe(`code ${index}`)
    })
  }
})
