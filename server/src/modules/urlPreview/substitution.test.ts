import { describe, expect, test } from "bun:test"
import type { UrlPreviewResult } from "@inline-chat/url-preview"
import { resolveUrlPreviewSubstitution } from "./substitution"

function preview(overrides: Partial<UrlPreviewResult> = {}) {
  return {
    url: "https://example.com/page",
    finalUrl: "https://example.com/page",
    provider: "generic",
    title: "Example",
    ...overrides,
  } as UrlPreviewResult & { providerResourceType?: string }
}

describe("URL preview substitution policy", () => {
  test.each([
    ["repository", "https://github.com/vercel/chat", "GitHub - vercel/chat: A chat SDK", "vercel/chat"],
    ["issue", "https://github.com/vercel/chat/issues/42", "Bug · Issue #42 · vercel/chat", "vercel/chat#42"],
    ["pull request", "https://github.com/vercel/chat/pull/43", "Fix · Pull Request #43 · vercel/chat", "vercel/chat#43"],
  ])("substitutes a clean GitHub %s", (_kind, url, title, expected) => {
    expect(resolveUrlPreviewSubstitution(preview({ url, finalUrl: url, title }))).toEqual({
      canSubstitute: true,
      title: expected,
    })
  })

  test.each([
    "https://github.com/vercel/chat/tree/main",
    "https://github.com/vercel/chat/issues/42/files",
    "https://github.com/vercel/chat/pull/43?diff=split",
    "https://github.com/vercel/chat/pull/43#discussion_r1",
    "https://github.com/features/actions",
  ])("keeps non-resource GitHub URL literal: %s", (url) => {
    expect(resolveUrlPreviewSubstitution(preview({ url, finalUrl: url, title: "GitHub - vercel/chat" })))
      .toEqual({ canSubstitute: false })
  })

  test("requires the resolved GitHub page to identify the repository", () => {
    const url = "https://github.com/vercel/chat"
    expect(resolveUrlPreviewSubstitution(preview({ url, finalUrl: url, title: "GitHub" })))
      .toEqual({ canSubstitute: false })
  })

  test.each(["notion.page", "notion.database", "notion.data_source"])("substitutes %s", (providerResourceType) => {
    expect(resolveUrlPreviewSubstitution({
      ...preview({ provider: "notion", title: "Roadmap" }),
      providerResourceType,
    })).toEqual({ canSubstitute: true, title: "Roadmap" })
  })

  test.each(["notion.block", "notion.file", undefined])(
    "keeps %s literal",
    (providerResourceType) => {
      expect(resolveUrlPreviewSubstitution({
        ...preview({ provider: "notion", title: "Roadmap" }),
        providerResourceType,
      })).toEqual({ canSubstitute: false })
    },
  )

  test("substitutes only classified Linear issues", () => {
    expect(resolveUrlPreviewSubstitution({
      ...preview({ provider: "linear", title: "ENG-42 · Fix compose" }),
      providerResourceType: "linear.issue",
    })).toEqual({ canSubstitute: true, title: "ENG-42 · Fix compose" })
    expect(resolveUrlPreviewSubstitution(preview({ provider: "linear", title: "Project" })))
      .toEqual({ canSubstitute: false })
  })

  test("keeps unusually long provider titles literal", () => {
    expect(resolveUrlPreviewSubstitution({
      ...preview({ provider: "notion", title: "x".repeat(121) }),
      providerResourceType: "notion.page",
    })).toEqual({ canSubstitute: false })
  })
})
