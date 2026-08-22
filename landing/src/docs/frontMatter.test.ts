import { describe, expect, it } from "vitest"
import { parseDocsFrontMatter, resolveDocsMarkdown, serializeDocsFrontMatter } from "./frontMatter"

describe("docs front matter", () => {
  it("leaves ordinary Markdown unchanged", () => {
    const source = "# Origin Story\n\nStart writing.\n"

    expect(resolveDocsMarkdown(source, "Origin Story")).toEqual({
      title: "Origin Story",
      markdown: source,
      frontMatter: {},
    })
  })

  it("resolves optional title, author, and date fields", () => {
    const source = [
      "---",
      'title: "Inline: the public beta"',
      "author: Mo",
      "date: August 18, 2026",
      "---",
      "",
      "# Old title",
      "",
      "Start writing.",
    ].join("\n")

    expect(resolveDocsMarkdown(source, "Fallback")).toEqual({
      title: "Inline: the public beta",
      markdown: "# Inline: the public beta\n\nStart writing.",
      frontMatter: {
        title: "Inline: the public beta",
        author: "Mo",
        date: "August 18, 2026",
      },
    })
  })

  it("supports metadata without a title override", () => {
    const source = "---\nauthor: Mo\n---\n\n# Existing title\n"

    expect(resolveDocsMarkdown(source, "Registered title")).toEqual({
      title: "Registered title",
      markdown: "# Existing title\n",
      frontMatter: { author: "Mo" },
    })
  })

  it("adds the overridden title when the body has no H1", () => {
    const source = "---\ntitle: Public beta\n---\n\nOpening paragraph."

    expect(resolveDocsMarkdown(source, "Fallback").markdown).toBe("# Public beta\n\nOpening paragraph.")
  })

  it("rejects malformed or unsupported front matter", () => {
    expect(() => parseDocsFrontMatter("---\nauthor: Mo\n")).toThrow("missing its closing")
    expect(() => parseDocsFrontMatter("---\ntags: beta\n---\n")).toThrow("Unsupported")
  })

  it("serializes only authored metadata", () => {
    expect(serializeDocsFrontMatter({ title: "Public beta", author: "Mo" })).toBe(
      '---\ntitle: "Public beta"\nauthor: "Mo"\n---',
    )
    expect(serializeDocsFrontMatter({})).toBe("")
  })
})
