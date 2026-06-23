import { describe, expect, test } from "bun:test"
import { parseRichMarkdown } from "@in/server/modules/message/richText"
import { cleanStreamingMarkdown, parseChatgptMarkdownOutput } from "./outputMarkdown"

describe("ChatGPT output markdown", () => {
  test("preserves HTTPS markdown images for final rich Markdown", () => {
    const output = parseChatgptMarkdownOutput("Here you go.\n\n![Cockatiel](https://example.com/bird.jpg)")

    expect(output.text).toBe("Here you go.\n\n![Cockatiel](https://example.com/bird.jpg)")
  })

  test("preserves HTTPS markdown image URLs that contain parentheses", () => {
    const url = "https://upload.wikimedia.org/wikipedia/commons/thumb/1/1f/Cockatiel_(Nymphicus_hollandicus).jpg/800px-Cockatiel_(Nymphicus_hollandicus).jpg"
    const output = parseChatgptMarkdownOutput(`Here you go.\n\n![Cockatiel](${url})`)

    expect(output.text).toBe(`Here you go.\n\n![Cockatiel](${url})`)
  })

  test("keeps non-HTTPS image embeds as text without sending media", () => {
    const output = parseChatgptMarkdownOutput("![x](http://example.com/x.jpg)\n\nFallback")

    expect(output.text).toBe("![x](http://example.com/x.jpg)\n\nFallback")
  })

  test("keeps rich image embeds in final text instead of applying the old separate-send limit", () => {
    const markdown = Array.from({ length: 10 }, (_, index) => `![image ${index}](https://example.com/${index}.jpg)`).join("\n")
    const output = parseChatgptMarkdownOutput(`${markdown}\n\nDone`)

    expect(output.text).toBe(`${markdown}\n\nDone`)
  })

  test("preserves final rich Markdown block syntax for the canonical parser", () => {
    const output = parseChatgptMarkdownOutput("# Result\n\n- [x] shipped\n\n| A | B |\n| --- | --- |\n| 1 | 2 |")

    expect(output.text).toBe("# Result\n\n- [x] shipped\n\n| A | B |\n| --- | --- |\n| 1 | 2 |")
  })

  test("final preserved markdown image is parsed as a rich photo block", () => {
    const output = parseChatgptMarkdownOutput("# Result\n\n![Cockatiel](https://example.com/bird.jpg)")
    const rich = parseRichMarkdown(output.text)

    expect(rich.blocks.map((block) => block.block.oneofKind)).toEqual(["heading", "photo"])
    expect(rich.blocks[1]?.block.oneofKind === "photo" ? rich.blocks[1].block.photo.media?.media : undefined).toEqual({
      oneofKind: "publicUrl",
      publicUrl: "https://example.com/bird.jpg",
    })
  })

  test("streaming cleanup strips image embeds before rich Markdown parsing", () => {
    expect(cleanStreamingMarkdown("Generating:\n\n![Preview](https://example.com/preview.png)")).toBe("Generating:")
  })

  test("streaming cleanup preserves links while stripping image embeds", () => {
    expect(
      cleanStreamingMarkdown(
        "See [source](https://example.com/source).\n\n![Preview](http://example.com/preview.png)",
      ),
    ).toBe("See [source](https://example.com/source).")
  })

})
