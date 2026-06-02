import { describe, expect, it } from "bun:test"
import type { FetchUrlPreviewOptions } from "../../../../types"
import { extractPreviewRoutes, fetchAuthenticatedUrlPreview } from "../../../index"
import { parseNotionUrl } from "./index"

const token = { provider: "notion", accessToken: "secret-token" }

describe("notion authenticated preview provider", () => {
  it("parses page and block URLs into typed provider targets", () => {
    const page = parseNotionUrl("https://www.notion.so/workspace/Roadmap-0123456789abcdef0123456789abcdef?pvs=4")
    expect(page).toMatchObject({
      provider: "notion",
      resourceType: "unknown",
      resourceId: "01234567-89ab-cdef-0123-456789abcdef",
      normalizedUrl: "https://www.notion.so/workspace/Roadmap-0123456789abcdef0123456789abcdef",
    })

    const block = parseNotionUrl(
      "https://www.notion.so/workspace/Roadmap-0123456789abcdef0123456789abcdef#fedcba9876543210fedcba9876543210",
    )
    expect(block).toMatchObject({
      provider: "notion",
      resourceType: "block",
      resourceId: "fedcba98-7654-3210-fedc-ba9876543210",
    })
  })

  it("extracts protected Notion URLs without enabling public generic fetching", () => {
    const routes = extractPreviewRoutes(
      "see https://www.notion.so/workspace/Roadmap-0123456789abcdef0123456789abcdef and https://example.com/a",
    )

    expect(routes).toHaveLength(2)
    expect(routes[0]?.kind).toBe("authenticated")
    expect(routes[1]).toEqual({ kind: "general", url: "https://example.com/a" })
  })

  it("fetches database names and keeps the original Notion link", async () => {
    const parsed = parseNotionUrl("https://www.notion.so/workspace/Tasks-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    if (!parsed) throw new Error("Expected parsed Notion URL")

    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url, init) => {
      expect(String(url)).toBe("https://api.notion.com/v1/pages/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
      expect(new Headers(init?.headers).get("Authorization")).toBe("Bearer secret-token")
      return new Response(JSON.stringify({ object: "page" }), { status: 404 })
    }

    const databaseFetch: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url, init) => {
      if (String(url).includes("/pages/")) {
        return fetchImpl(url, init)
      }

      expect(String(url)).toBe("https://api.notion.com/v1/databases/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
      return new Response(
        JSON.stringify({
          object: "database",
          title: [{ plain_text: "Product roadmap" }],
          description: [{ plain_text: "Company project tracker" }],
          data_sources: [{ id: "source-a", name: "Projects" }],
        }),
        { headers: { "content-type": "application/json" } },
      )
    }

    const preview = await fetchAuthenticatedUrlPreview(parsed, token, { fetchImpl: databaseFetch })

    expect(preview).toMatchObject({
      provider: "notion",
      providerResourceType: "notion.database",
      title: "Product roadmap",
      url: parsed.normalizedUrl,
      finalUrl: parsed.normalizedUrl,
      siteName: "Notion",
      description: "Company project tracker",
    })
  })

  it("fetches data source titles and descriptions from current Notion fields", async () => {
    const parsed = parseNotionUrl("https://www.notion.so/workspace/Tasks-dddddddddddddddddddddddddddddddd")
    if (!parsed) throw new Error("Expected parsed Notion URL")

    const fetchedUrls: string[] = []
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      fetchedUrls.push(String(url))
      if (String(url).includes("/pages/") || String(url).includes("/databases/")) {
        return new Response(JSON.stringify({ object: "page" }), { status: 404 })
      }

      expect(String(url)).toBe("https://api.notion.com/v1/data_sources/dddddddd-dddd-dddd-dddd-dddddddddddd")
      return new Response(
        JSON.stringify({
          object: "data_source",
          title: [{ plain_text: "Projects" }],
          description: [{ plain_text: "Active work by team." }],
        }),
        { headers: { "content-type": "application/json" } },
      )
    }

    const preview = await fetchAuthenticatedUrlPreview(parsed, token, { fetchImpl })

    expect(fetchedUrls).toEqual([
      "https://api.notion.com/v1/pages/dddddddd-dddd-dddd-dddd-dddddddddddd",
      "https://api.notion.com/v1/databases/dddddddd-dddd-dddd-dddd-dddddddddddd",
      "https://api.notion.com/v1/data_sources/dddddddd-dddd-dddd-dddd-dddddddddddd",
    ])
    expect(preview).toMatchObject({
      provider: "notion",
      providerResourceType: "notion.data_source",
      title: "Projects",
      description: "Active work by team.",
      mediaType: "article",
    })
  })

  it("uses actual page description text instead of generated labels", async () => {
    const parsed = parseNotionUrl("https://www.notion.so/workspace/Tasks-cccccccccccccccccccccccccccccccc")
    if (!parsed) throw new Error("Expected parsed Notion URL")

    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      expect(String(url)).toBe("https://api.notion.com/v1/pages/cccccccc-cccc-cccc-cccc-cccccccccccc")
      return new Response(
        JSON.stringify({
          object: "page",
          properties: {
            Name: {
              type: "title",
              title: [{ plain_text: "Q3 planning" }],
            },
            Description: {
              type: "rich_text",
              rich_text: [{ plain_text: "Planning notes and launch scope." }],
            },
            Files: {
              type: "files",
              files: [{ name: "Scope.pdf" }],
            },
          },
        }),
        { headers: { "content-type": "application/json" } },
      )
    }

    const preview = await fetchAuthenticatedUrlPreview(parsed, token, { fetchImpl })

    expect(preview).toMatchObject({
      provider: "notion",
      providerResourceType: "notion.page",
      title: "Q3 planning",
      description: "Planning notes and launch scope.",
      mediaType: "document",
    })
    expect(preview?.description).not.toContain("Files")
    expect(preview?.description).not.toContain("Notion page")
  })

  it("fetches file block names without exposing signed Notion file URLs as media", async () => {
    const parsed = parseNotionUrl(
      "https://www.notion.so/workspace/Page-0123456789abcdef0123456789abcdef#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    )
    if (!parsed) throw new Error("Expected parsed Notion URL")

    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      expect(String(url)).toBe("https://api.notion.com/v1/blocks/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
      return new Response(
        JSON.stringify({
          object: "block",
          type: "file",
          file: {
            type: "file",
            file: {
              url: "https://s3.us-west-2.amazonaws.com/secure.notion-static.com/private/Specs.pdf?token=secret",
            },
          },
        }),
        { headers: { "content-type": "application/json" } },
      )
    }

    const preview = await fetchAuthenticatedUrlPreview(parsed, token, { fetchImpl })

    expect(preview).toMatchObject({
      provider: "notion",
      providerResourceType: "notion.file",
      title: "Specs.pdf",
      url: parsed.normalizedUrl,
      mediaType: "document",
    })
    expect(preview?.media).toBeUndefined()
    expect(preview?.description).toBeUndefined()
    expect(JSON.stringify(preview)).not.toContain("s3.us-west-2.amazonaws.com")
    expect(JSON.stringify(preview)).not.toContain("token=secret")
  })

  it("does not retry block URLs through page or database endpoints", async () => {
    const parsed = parseNotionUrl(
      "https://www.notion.so/workspace/Page-0123456789abcdef0123456789abcdef#bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    )
    if (!parsed) throw new Error("Expected parsed Notion URL")

    const fetchedUrls: string[] = []
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      fetchedUrls.push(String(url))
      return new Response(JSON.stringify({ object: "block" }), { status: 404 })
    }

    const preview = await fetchAuthenticatedUrlPreview(parsed, token, { fetchImpl })

    expect(preview).toBeNull()
    expect(fetchedUrls).toEqual(["https://api.notion.com/v1/blocks/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"])
  })

  it("uses external file-like block URLs for names without returning generic labels", async () => {
    const parsed = parseNotionUrl(
      "https://www.notion.so/workspace/Page-0123456789abcdef0123456789abcdef#eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    )
    if (!parsed) throw new Error("Expected parsed Notion URL")

    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      expect(String(url)).toBe("https://api.notion.com/v1/blocks/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")
      return new Response(
        JSON.stringify({
          object: "block",
          type: "video",
          video: {
            caption: [],
            type: "external",
            external: {
              url: "https://cdn.example.com/team-demo.mp4",
            },
          },
        }),
        { headers: { "content-type": "application/json" } },
      )
    }

    const preview = await fetchAuthenticatedUrlPreview(parsed, token, { fetchImpl })

    expect(preview).toMatchObject({
      provider: "notion",
      providerResourceType: "notion.file",
      title: "team-demo.mp4",
      mediaType: "video",
    })
    expect(preview?.description).toBeUndefined()
    expect(preview?.media).toBeUndefined()
  })

  it("omits titles for unnamed file-like blocks so clients can show the provider", async () => {
    const parsed = parseNotionUrl(
      "https://www.notion.so/workspace/Page-0123456789abcdef0123456789abcdef#ffffffffffffffffffffffffffffffff",
    )
    if (!parsed) throw new Error("Expected parsed Notion URL")

    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async () =>
      new Response(
        JSON.stringify({
          object: "block",
          type: "video",
          video: {
            caption: [],
            type: "file_upload",
            file_upload: {
              id: "upload-id",
            },
          },
        }),
        { headers: { "content-type": "application/json" } },
      )

    const preview = await fetchAuthenticatedUrlPreview(parsed, token, { fetchImpl })

    expect(preview).toMatchObject({
      provider: "notion",
      providerResourceType: "notion.file",
      mediaType: "video",
    })
    expect(preview?.title).toBeUndefined()
    expect(preview?.description).toBeUndefined()
  })

  it("does not fetch with credentials from another provider", async () => {
    const parsed = parseNotionUrl("https://www.notion.so/workspace/Tasks-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    if (!parsed) throw new Error("Expected parsed Notion URL")

    let called = false
    const preview = await fetchAuthenticatedUrlPreview(parsed, { provider: "linear", accessToken: "secret-token" }, {
      fetchImpl: async () => {
        called = true
        return new Response("{}")
      },
    })

    expect(preview).toBeNull()
    expect(called).toBeFalse()
  })
})
