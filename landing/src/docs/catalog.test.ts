import { describe, expect, it } from "vitest"
import { createDocsPages } from "./catalog"
import { docsPublicationOrder, resolveDocsSidebar } from "./sidebar"

const markdown = (title: string, draft = false) =>
  `---\ntitle: ${title}\ndescription: ${title} description.\n${draft ? "draft: true\n" : ""}---\n\nBody.`

describe("docs catalog", () => {
  it("derives stable routes from filenames", () => {
    const pages = createDocsPages([
      { path: "./content/index.md", markdown: markdown("Get Started") },
      { path: "./content/origin-story.md", markdown: markdown("Origin Story") },
      { path: "./content/technical/index.md", markdown: markdown("Technical") },
      { path: "./content/technical/realtime.md", markdown: markdown("Realtime") },
    ])

    expect(pages.map(({ slug, route, markdownPath }) => ({ slug, route, markdownPath }))).toEqual([
      { slug: "index", route: "/docs", markdownPath: "/docs/index.md" },
      { slug: "origin-story", route: "/docs/origin-story", markdownPath: "/docs/origin-story.md" },
      { slug: "technical/index", route: "/docs/technical", markdownPath: "/docs/technical/index.md" },
      {
        slug: "technical/realtime",
        route: "/docs/technical/realtime",
        markdownPath: "/docs/technical/realtime.md",
      },
    ])
  })

  it("requires an index and lowercase kebab-case filenames", () => {
    expect(() => createDocsPages([{ path: "./content/Origin Story.md", markdown: markdown("Origin") }])).toThrow(
      "lowercase kebab-case segments",
    )
    expect(() => createDocsPages([{ path: "./content/page.md", markdown: markdown("Page") }])).toThrow(
      "content/index.md",
    )
  })
})

describe("docs sidebar", () => {
  const pages = createDocsPages([
    { path: "./content/index.md", markdown: markdown("Get Started") },
    { path: "./content/origin-story.md", markdown: markdown("Origin Story", true) },
    { path: "./content/security.md", markdown: markdown("Security") },
    { path: "./content/unlisted.md", markdown: markdown("Unlisted") },
  ])
  const config = {
    groups: [
      {
        title: "Start",
        pages: ["index", { slug: "origin-story", label: "Origin" }, "security"],
      },
      {
        title: "Links",
        pages: [{ label: "Legal", href: "/legal", external: true }],
      },
    ],
  }

  it("shows drafts only when explicitly requested", () => {
    expect(resolveDocsSidebar(config, pages, false).groups[0].items.map((item) => item.title)).toEqual([
      "Get Started",
      "Security",
    ])
    expect(resolveDocsSidebar(config, pages, true).groups[0].items).toContainEqual({
      title: "Origin",
      to: "/docs/origin-story",
      draft: true,
    })
  })

  it("orders published pages by the sidebar and appends unlisted pages", () => {
    expect(docsPublicationOrder(config, pages).map((page) => page.slug)).toEqual(["index", "security", "unlisted"])
  })

  it("combines primary and section sidebars in publication order", () => {
    const sectionConfig = {
      groups: [{ title: "Section", pages: ["unlisted"] }],
    }
    expect(docsPublicationOrder([config, sectionConfig], pages).map((page) => page.slug)).toEqual([
      "index",
      "security",
      "unlisted",
    ])
  })

  it("rejects pages repeated across sidebars", () => {
    expect(() =>
      docsPublicationOrder([config, { groups: [{ title: "Again", pages: ["security"] }] }], pages),
    ).toThrow("Duplicate docs publication page")
  })

  it("rejects unknown and duplicate page references", () => {
    expect(() => resolveDocsSidebar({ groups: [{ title: "Bad", pages: ["missing"] }] }, pages, true)).toThrow(
      "Unknown",
    )
    expect(() =>
      resolveDocsSidebar({ groups: [{ title: "Bad", pages: ["index", "index"] }] }, pages, true),
    ).toThrow("Duplicate")
  })

  it("rejects unsafe sidebar links", () => {
    expect(() =>
      resolveDocsSidebar(
        { groups: [{ title: "Bad", pages: [{ label: "Bad", href: "javascript:alert(1)" }] }] },
        pages,
        true,
      ),
    ).toThrow("root-relative or HTTP(S)")
  })
})
