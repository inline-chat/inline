import { describe, expect, it } from "bun:test"
import {
  extractPreviewUrl,
  extractPreviewUrls,
  fetchBinary,
  fetchUrlPreview,
  isYouTubeUrl,
  normalizePreviewUrl,
  normalizeYouTubeUrl,
  type FetchBinaryOptions,
  type FetchUrlPreviewOptions,
} from "./index"

const publicLookup: NonNullable<FetchUrlPreviewOptions["lookup"]> = async () => [
  { address: "93.184.216.34", family: 4 },
]

const privateLookup: NonNullable<FetchUrlPreviewOptions["lookup"]> = async () => [
  { address: "127.0.0.1", family: 4 },
]

describe("url-preview", () => {
  it("extracts and normalizes previewable urls from text", () => {
    expect(extractPreviewUrl("see https://example.com/path).")).toBe("https://example.com/path")
    expect(extractPreviewUrl("go to www.example.com/a?b=1")).toBe("https://www.example.com/a?b=1")
    expect(extractPreviewUrl("plain text")).toBeNull()
  })

  it("prefers entity candidates over raw text", () => {
    expect(extractPreviewUrl("https://first.example", ["https://second.example"])).toBe("https://second.example/")
  })

  it("rejects unsafe or unsupported urls before fetching", () => {
    expect(normalizePreviewUrl("javascript:alert(1)")).toBeNull()
    expect(normalizePreviewUrl("http://localhost:3000")).toBeNull()
    expect(normalizePreviewUrl("http://127.0.0.1")).toBeNull()
    expect(normalizePreviewUrl("http://[::1]")).toBeNull()
    expect(normalizePreviewUrl("http://[::ffff:7f00:1]")).toBeNull()
    expect(normalizePreviewUrl("http://[fd00::1]")).toBeNull()
    expect(normalizePreviewUrl("https://user:pass@example.com")).toBeNull()
  })

  it("rejects protected and sensitive unauthenticated preview urls", () => {
    expect(normalizePreviewUrl("https://inline.sentry.io/issues/123")).toBeNull()
    expect(normalizePreviewUrl("https://linear.app/inline/issue/ABC-1/private")).toBeNull()
    expect(normalizePreviewUrl("https://app.notion.com/p/workspace/Page-0123456789abcdef0123456789abcdef")).toBeNull()
    expect(normalizePreviewUrl("https://future.notion.com/p/workspace/Page-0123456789abcdef0123456789abcdef")).toBeNull()
    expect(normalizePreviewUrl("https://www.notion.so/workspace/secret")).toBeNull()
    expect(normalizePreviewUrl("https://1password.com/signin")).toBeNull()
    expect(normalizePreviewUrl("https://example.com/oauth/callback?code=abc")).toBeNull()
    expect(normalizePreviewUrl("https://example.com/oauth2/authorize?client_id=abc")).toBeNull()
    expect(normalizePreviewUrl("https://example.com/email-verification?token=abc")).toBeNull()
    expect(normalizePreviewUrl("https://example.com/oauth-callback")).toBeNull()
    expect(normalizePreviewUrl("https://example.com/sign-in")).toBeNull()
    expect(normalizePreviewUrl("https://example.com/path?accessToken=abc")).toBeNull()
  })

  it("does not reject harmless words that contain sensitive substrings", () => {
    expect(normalizePreviewUrl("https://example.com/authors/mo?author=inline&monkey=banana")).toBe(
      "https://example.com/authors/mo?author=inline&monkey=banana",
    )
  })

  it("strips tracking query data and extracts multiple deduped urls", () => {
    expect(normalizePreviewUrl("https://example.com/a?utm_source=x&b=1#secret")).toBe("https://example.com/a?b=1")
    expect(
      extractPreviewUrls(
        "https://first.example/x https://first.example/x https://second.example/a?utm_campaign=y",
        ["https://entity.example"],
      ),
    ).toEqual(["https://entity.example/", "https://first.example/x", "https://second.example/a"])
  })

  it("parses generic html metadata with bounded description", async () => {
    let fetchedUrl: string | undefined
    const html = `
      <html>
        <head>
          <title>Fallback title</title>
          <meta property="og:site_name" content="Example">
          <meta property="og:title" content="Open Graph Title">
          <meta name="description" content="${"Long ".repeat(80)}">
          <meta property="og:image" content="/preview.png">
        </head>
      </html>
    `
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      fetchedUrl = String(url)
      return new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } })
    }

    const preview = await fetchUrlPreview("https://example.com/a", {
      fetchImpl,
      lookup: publicLookup,
      maxDescriptionLength: 60,
    })

    expect(fetchedUrl).toBe("https://example.com/a")
    expect(preview?.provider).toBe("generic")
    expect(preview?.siteName).toBe("Example")
    expect(preview?.title).toBe("Open Graph Title")
    expect(preview?.description?.length).toBeLessThanOrEqual(60)
    expect(preview?.imageUrl).toBe("https://example.com/preview.png")
    expect(preview?.mediaType).toBeUndefined()
  })

  it("detects generic articles only from explicit metadata", async () => {
    const html = `
      <html>
        <head>
          <meta property="og:type" content="article">
          <meta property="og:title" content="Article title">
        </head>
      </html>
    `
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async () =>
      new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } })

    const preview = await fetchUrlPreview("https://example.com/story", { fetchImpl, lookup: publicLookup })

    expect(preview?.mediaType).toBe("article")
  })

  it("detects generic video pages from metadata without provider-specific hosts", async () => {
    const html = `
      <html>
        <head>
          <meta property="og:title" content="Self-hosted recording">
          <meta property="og:description" content="Watch this video">
          <meta property="og:image" content="https://cap.example/api/video/og?id=abc">
          <meta property="og:video" content="https://cap.example/api/playlist?id=abc">
          <meta property="og:video:type" content="video/mp4">
          <meta name="twitter:card" content="player">
          <meta name="twitter:player" content="https://cap.example/s/abc">
        </head>
      </html>
    `
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async () =>
      new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } })

    const preview = await fetchUrlPreview("https://cap.example/s/abc", { fetchImpl, lookup: publicLookup })

    expect(preview).toMatchObject({
      provider: "generic",
      siteName: "cap.example",
      title: "Self-hosted recording",
      description: "Watch this video",
      imageUrl: "https://cap.example/api/video/og?id=abc",
      mediaType: "video",
      media: {
        kind: "external_video",
        url: "https://cap.example/api/playlist?id=abc",
        mimeType: "video/mp4",
      },
      layout: {
        hasLargeMedia: true,
        showLargeMedia: true,
      },
    })
  })

  it("follows safe redirects and records the final url", async () => {
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      if (String(url) === "https://example.com/start") {
        return new Response(null, { status: 302, headers: { location: "/final" } })
      }
      return new Response("<title>Final</title>", { headers: { "content-type": "text/html" } })
    }

    const preview = await fetchUrlPreview("https://example.com/start", { fetchImpl, lookup: publicLookup })
    expect(preview?.finalUrl).toBe("https://example.com/final")
    expect(preview?.title).toBe("Final")
  })

  it("normalizes safe redirect targets before fetching them", async () => {
    const fetchedUrls: string[] = []
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      fetchedUrls.push(String(url))
      if (String(url) === "https://example.com/start") {
        return new Response(null, { status: 302, headers: { location: "/final?utm_source=x&b=1" } })
      }
      return new Response("<title>Final</title>", { headers: { "content-type": "text/html" } })
    }

    const preview = await fetchUrlPreview("https://example.com/start", { fetchImpl, lookup: publicLookup })
    expect(fetchedUrls).toEqual(["https://example.com/start", "https://example.com/final?b=1"])
    expect(preview?.finalUrl).toBe("https://example.com/final?b=1")
  })

  it("rejects sensitive redirect targets before fetching them", async () => {
    const fetchedUrls: string[] = []
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      fetchedUrls.push(String(url))
      if (String(url) === "https://example.com/start") {
        return new Response(null, { status: 302, headers: { location: "/oauth/callback?code=secret" } })
      }
      throw new Error("sensitive redirect target should not be fetched")
    }

    await expect(fetchUrlPreview("https://example.com/start", { fetchImpl, lookup: publicLookup })).rejects.toThrow()
    expect(fetchedUrls).toEqual(["https://example.com/start"])
  })

  it("reads a bounded html prefix instead of failing large pages", async () => {
    const prefix = "<html><head><title>Large page</title></head><body>"
    const body = `${prefix}${"x".repeat(2_000)}</body></html>`
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async () =>
      new Response(body, {
        headers: {
          "content-type": "text/html",
          "content-length": String(body.length),
        },
      })

    const preview = await fetchUrlPreview("https://example.com/large", {
      fetchImpl,
      lookup: publicLookup,
      maxHtmlBytes: 256,
    })

    expect(preview?.title).toBe("Large page")
  })

  it("does not call fetch for dns-private targets", async () => {
    let called = false
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async () => {
      called = true
      return new Response("")
    }

    await expect(fetchUrlPreview("https://example.com", { fetchImpl, lookup: privateLookup })).rejects.toThrow()
    expect(called).toBe(false)
  })

  it("uses Loom oEmbed metadata for Loom share links", async () => {
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      expect(String(url)).toStartWith("https://www.loom.com/v1/oembed?")
      return Response.json({
        title: "Demo recording",
        description: "Short demo",
      thumbnail_url: "https://cdn.loom.com/thumb.jpg",
      duration: 82.4,
      html: '<iframe src="https://www.loom.com/embed/abc123"></iframe>',
      width: 640,
      height: 360,
    })
    }

    const preview = await fetchUrlPreview("https://www.loom.com/share/abc123", { fetchImpl, lookup: publicLookup })
    expect(preview).toMatchObject({
      provider: "loom",
      siteName: "Loom",
      title: "Demo recording",
      imageUrl: "https://cdn.loom.com/thumb.jpg",
      duration: 82,
      mediaType: "video",
      media: {
        kind: "embed",
        url: "https://www.loom.com/embed/abc123",
        embedType: "iframe",
        width: 640,
        height: 360,
        duration: 82,
      },
    })
  })

  it("uses YouTube oEmbed metadata for YouTube watch, short and shortener links", async () => {
    expect(isYouTubeUrl("https://youtu.be/abcDEF12345?si=share")).toBe(true)
    expect(normalizeYouTubeUrl("https://www.youtube.com/shorts/abcDEF12345?feature=share")).toBe(
      "https://www.youtube.com/watch?v=abcDEF12345",
    )

    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      const endpoint = new URL(String(url))
      expect(`${endpoint.origin}${endpoint.pathname}`).toBe("https://www.youtube.com/oembed")
      expect(endpoint.searchParams.get("url")).toBe("https://www.youtube.com/watch?v=abcDEF12345")
      return Response.json({
      title: "Demo video",
      author_name: "Inline",
      thumbnail_url: "https://i.ytimg.com/vi/abcDEF12345/hqdefault.jpg",
      width: 480,
      height: 270,
    })
    }

    const preview = await fetchUrlPreview("https://youtu.be/abcDEF12345?si=share", { fetchImpl, lookup: publicLookup })
    expect(preview).toMatchObject({
      provider: "youtube",
      siteName: "YouTube",
      author: "Inline",
      title: "Demo video",
      imageUrl: "https://i.ytimg.com/vi/abcDEF12345/hqdefault.jpg",
      mediaType: "video",
      media: {
        kind: "embed",
        url: "https://www.youtube.com/embed/abcDEF12345",
        embedType: "iframe",
        width: 480,
        height: 270,
      },
    })
  })

  it("uses bounded YouTube page metadata when YouTube oEmbed is unavailable", async () => {
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      const urlString = String(url)
      if (urlString.startsWith("https://www.youtube.com/oembed?")) {
        return new Response("forbidden", { status: 403, headers: { "content-type": "text/html" } })
      }

      expect(urlString).toBe("https://www.youtube.com/watch?v=abcDEF12345")
      return new Response(
        `<html><head>
          <title>Fallback title - YouTube</title>
          <meta property="og:title" content="Page title">
          <meta property="og:image" content="https://i.ytimg.com/vi/abcDEF12345/maxresdefault.jpg">
        </head></html>`,
        { headers: { "content-type": "text/html" } },
      )
    }

    const preview = await fetchUrlPreview("https://www.youtube.com/watch?v=abcDEF12345", {
      fetchImpl,
      lookup: publicLookup,
    })

    expect(preview).toMatchObject({
      provider: "youtube",
      siteName: "YouTube",
      title: "Page title",
      imageUrl: "https://i.ytimg.com/vi/abcDEF12345/maxresdefault.jpg",
      mediaType: "video",
      media: {
        kind: "embed",
        url: "https://www.youtube.com/embed/abcDEF12345",
        embedType: "iframe",
      },
    })
  })

  it("falls back to YouTube page metadata when oEmbed returns invalid json", async () => {
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      const urlString = String(url)
      if (urlString.startsWith("https://www.youtube.com/oembed?")) {
        return new Response("<html>blocked</html>", { headers: { "content-type": "text/html" } })
      }

      return new Response(
        `<html><head>
          <meta property="og:title" content="Recovered page title">
          <meta property="og:image" content="https://i.ytimg.com/vi/abcDEF12345/maxresdefault.jpg">
        </head></html>`,
        { headers: { "content-type": "text/html" } },
      )
    }

    const preview = await fetchUrlPreview("https://www.youtube.com/watch?v=abcDEF12345", {
      fetchImpl,
      lookup: publicLookup,
    })

    expect(preview?.title).toBe("Recovered page title")
    expect(preview?.media?.kind).toBe("embed")
  })

  it("uses deterministic YouTube fallback when oEmbed and page fetch fail", async () => {
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      const urlString = String(url)
      if (urlString.startsWith("https://www.youtube.com/oembed?")) {
        return new Response("x".repeat(200 * 1024), {
          headers: {
            "content-type": "application/json",
            "content-length": String(200 * 1024),
          },
        })
      }

      return new Response("forbidden", { status: 403 })
    }

    const preview = await fetchUrlPreview("https://www.youtube.com/watch?v=abcDEF12345", {
      fetchImpl,
      lookup: publicLookup,
    })

    expect(preview).toMatchObject({
      provider: "youtube",
      title: "YouTube video",
      imageUrl: "https://i.ytimg.com/vi/abcDEF12345/hqdefault.jpg",
      media: {
        kind: "embed",
        url: "https://www.youtube.com/embed/abcDEF12345",
      },
    })
  })

  it("does not fall back to generic page fetching for exclusive providers", async () => {
    const fetchedUrls: string[] = []
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      fetchedUrls.push(String(url))
      return new Response("not found", { status: 404, headers: { "content-type": "application/json" } })
    }

    const preview = await fetchUrlPreview("https://www.youtube.com/watch?v=abcDEF12345", {
      fetchImpl,
      lookup: publicLookup,
    })

    expect(preview).toMatchObject({
      provider: "youtube",
      siteName: "YouTube",
      title: "YouTube video",
      imageUrl: "https://i.ytimg.com/vi/abcDEF12345/hqdefault.jpg",
      mediaType: "video",
      media: {
        kind: "embed",
        url: "https://www.youtube.com/embed/abcDEF12345",
        embedType: "iframe",
      },
    })
    expect(fetchedUrls).toHaveLength(2)
    expect(fetchedUrls[0]).toStartWith("https://www.youtube.com/oembed?")
    expect(fetchedUrls[1]).toBe("https://www.youtube.com/watch?v=abcDEF12345")
  })

  it("fetches binary images with type and size checks", async () => {
    const options: FetchBinaryOptions = {
      lookup: publicLookup,
      fetchImpl: async () =>
        new Response(new Uint8Array([1, 2, 3]), { headers: { "content-type": "image/png" } }),
    }
    const image = await fetchBinary("https://example.com/image.png", options)
    expect(image?.contentType).toBe("image/png")
    expect(Array.from(image?.bytes ?? [])).toEqual([1, 2, 3])

    const html = await fetchBinary("https://example.com/page", {
      lookup: publicLookup,
      fetchImpl: async () => new Response("<html></html>", { headers: { "content-type": "text/html" } }),
    })
    expect(html).toBeNull()
  })
})
