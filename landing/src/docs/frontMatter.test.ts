import { describe, expect, it } from "vitest"
import { parseDocsFrontMatter, resolveDocsMarkdown, serializeDocsFrontMatter } from "./frontMatter"

const authored = (fields: string, body = "Opening paragraph.") => `---\n${fields}\n---\n\n${body}`

describe("docs front matter", () => {
  it("uses front matter as the canonical title and description", () => {
    const resolved = resolveDocsMarkdown(
      authored('title: "Origin Story"\ndescription: "How Inline came to be."\nauthor: Mo\ndate: 2026-08-26'),
    )

    expect(resolved).toMatchObject({
      title: "Origin Story",
      description: "How Inline came to be.",
      markdown: "# Origin Story\n\nOpening paragraph.",
      frontMatter: {
        title: "Origin Story",
        description: "How Inline came to be.",
        author: "Mo",
        date: "2026-08-26",
        draft: false,
      },
    })
  })

  it("marks drafts and replaces a redundant body H1", () => {
    const resolved = resolveDocsMarkdown(
      authored('title: "Public beta"\ndescription: "Announcement draft."\ndraft: true', "# Old title\n\nDraft body."),
    )

    expect(resolved.markdown).toBe("# Public beta\n\nDraft body.")
    expect(resolved.frontMatter.draft).toBe(true)
  })

  it("requires front matter, title, and description", () => {
    expect(() => parseDocsFrontMatter("# Missing metadata\n")).toThrow("require front matter")
    expect(() => parseDocsFrontMatter(authored('description: "Missing title"'))).toThrow("title")
    expect(() => parseDocsFrontMatter(authored('title: "Missing description"'))).toThrow("description")
  })

  it("rejects unsupported fields and non-boolean draft values", () => {
    expect(() => parseDocsFrontMatter(authored('title: Page\ndescription: Summary\ntags: docs'))).toThrow(
      "Unsupported",
    )
    expect(() => parseDocsFrontMatter(authored('title: Page\ndescription: Summary\ndraft: yes'))).toThrow(
      "draft must be true or false",
    )
  })

  it("serializes public metadata without inventing draft state", () => {
    expect(
      serializeDocsFrontMatter({
        title: "Origin Story",
        description: "How Inline came to be.",
        author: "Mo",
        draft: false,
      }),
    ).toBe(
      '---\ntitle: "Origin Story"\ndescription: "How Inline came to be."\nauthor: "Mo"\n---',
    )
  })
})
