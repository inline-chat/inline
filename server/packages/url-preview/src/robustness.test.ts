import { describe, expect, it } from "bun:test"
import { fetchBinary, fetchUrlPreview, normalizePreviewUrl, type PreviewDiagnostic } from "./index.js"
import { fetchWithRedirects } from "./network.js"

const lookup = async () => [{ address: "93.184.216.34", family: 4 }]

describe("preview safety and recovery", () => {
  it.each([
    "https://example.com/?confirmation",
    "https://example.com/?confirm=1",
    "https://example.com/?token=",
    "https://example.com/?mode=verifyEmail&opaque=abc",
    "https://example.com/?mode=resetPassword&opaque=abc",
    "https://example.com/?type=magiclink&opaque=abc",
    "https://example.com/magiclink/abc",
    "https://example.com/?next=%2Fconfirm%2Fabc",
    "https://example.com/?url=https%3A%2F%2Faccounts.example%2F%3Ftoken%3Dabc",
    "https://example.com/?returnTo=https%3A%2F%2Faccounts.example%2F%3Fmode%3DverifyEmail",
    "https://app.notion.so./private",
    "https://inline.sentry.io./issues/123",
    "http://localhost./",
    "http://[fec0::1]/",
    "http://[::7f00:1]/",
  ])("never fetches the sensitive destination %s", async (url) => {
    let requests = 0
    expect(normalizePreviewUrl(url)).toBeNull()
    expect(await fetchUrlPreview(url, {
      lookup,
      fetchImpl: async () => { requests++; return new Response("unexpected") },
    })).toBeNull()
    expect(requests).toBe(0)
  })

  it("keeps ordinary content, signed images, and public redirect destinations eligible", () => {
    for (const url of [
      "https://example.com/authors/inline?author=inline&monkey=banana",
      "https://example.com/?type=video&mode=dark",
      "https://example.com/?next=%2Fdocs%2Fintro",
      "https://cdn.example.com/image.png?signature=abc&expires=123",
      "https://[2606:4700:4700::1111]/",
      "https://[::ffff:8.8.8.8]/",
    ]) {
      expect(normalizePreviewUrl(url)).not.toBeNull()
    }
  })

  it("reports upstream status without retaining a rejected body or private URL", async () => {
    const diagnostics: PreviewDiagnostic[] = []
    let cancelled = false
    await expect(fetchUrlPreview("https://example.com/private-id?search=private-value", {
      lookup,
      onDiagnostic: (diagnostic) => { diagnostics.push(diagnostic) },
      fetchImpl: async () => new Response(new ReadableStream({ cancel() { cancelled = true } }), { status: 429 }),
    })).rejects.toMatchObject({ code: "http_status", status: 429 })
    expect(cancelled).toBe(true)
    expect(diagnostics).toEqual([expect.objectContaining({
      stage: "generic", outcome: "error", code: "http_status", status: 429,
    })])
    expect(JSON.stringify(diagnostics)).not.toContain("private")
  })

  it("isolates telemetry failures and records empty metadata", async () => {
    const diagnostics: PreviewDiagnostic[] = []
    expect(await fetchUrlPreview("https://example.com/", {
      lookup,
      fetchImpl: async () => new Response("<html></html>"),
      onDiagnostic: (diagnostic) => { diagnostics.push(diagnostic); throw new Error("telemetry unavailable") },
    })).toBeNull()
    expect(diagnostics).toEqual([expect.objectContaining({ outcome: "empty", code: "no_metadata" })])
  })

  it("keeps a Cap-style secondary poster and HLS stream from streamed body metadata", async () => {
    const preview = await fetchUrlPreview("https://cap.example/s/recording", {
      lookup,
      fetchImpl: async () => new Response(`<!doctype html><html><head></head><body><div hidden>
        <meta property="og:title" content="A recording">
        <meta property="og:image" content="/api/video/preview?videoId=recording&amp;fallback=og">
        <meta property="og:image" content="/api/video/og?videoId=recording">
        <meta property="og:video:secure_url" content="/api/playlist?videoId=recording&amp;requireComplete=1">
        <meta property="og:video:type" content="application/vnd.apple.mpegurl">
      </div></body></html>`, { headers: { "content-type": "text/html" } }),
    })
    expect(preview).toMatchObject({
      title: "A recording",
      imageUrl: "https://cap.example/api/video/preview?videoId=recording&fallback=og",
      fallbackImageUrls: ["https://cap.example/api/video/og?videoId=recording"],
      media: { kind: "external_video", url: "https://cap.example/api/playlist?videoId=recording&requireComplete=1" },
    })
    let requests = 0
    await expect(fetchBinary(preview!.imageUrl!, {
      lookup,
      fetchImpl: async () => {
        requests++
        return new Response(null, { status: 302, headers: { location: "http://0.0.0.0:3000/api/video/og?videoId=recording" } })
      },
    })).rejects.toMatchObject({ code: "invalid_url" })
    expect(requests).toBe(1)
  })

  it("bounds X response-body stalls and falls back without exposing upstream errors", async () => {
    let cancelled = false
    const diagnostics: PreviewDiagnostic[] = []
    const preview = await fetchUrlPreview("https://x.com/inline/status/123", {
      lookup, timeoutMs: 20,
      onDiagnostic: (diagnostic) => { diagnostics.push(diagnostic) },
      fetchImpl: async (input) => String(input).includes("syndication")
        ? new Response(new ReadableStream({ cancel() { cancelled = true } }), { headers: { "content-type": "application/json" } })
        : new Response('<meta property="og:title" content="Fallback post">', { headers: { "content-type": "text/html" } }),
    })
    expect(cancelled).toBe(true)
    expect(preview?.title).toBe("Fallback post")
    expect(diagnostics).toEqual([
      expect.objectContaining({ stage: "provider", provider: "x", outcome: "error", code: "timeout" }),
      expect.objectContaining({ stage: "generic", outcome: "success" }),
    ])
  })

  it("accepts alternate X video payloads and skips unsafe or unsupported variants", async () => {
    const preview = await fetchUrlPreview("https://x.com/inline/status/123", {
      lookup,
      fetchImpl: async () => Response.json({
        __typename: "Tweet", text: "A video", user: { name: "Inline", screen_name: "inline" },
        video: {
          durationMs: 5_500, poster: "https://pbs.twimg.com/media/poster.jpg",
          variants: [
            { type: "video/mp4", src: "http://127.0.0.1/video.mp4" },
            { type: "text/html", src: "https://example.com/player" },
            { type: "video/mp4", src: "https://video.twimg.com/video/640x360/video.mp4" },
            { type: "video/mp4", src: "https://video.twimg.com/video/1280x720/video.mp4" },
          ],
        },
      }),
    })
    expect(preview?.media).toMatchObject({
      kind: "external_video", mimeType: "video/mp4", duration: 6,
      url: "https://video.twimg.com/video/1280x720/video.mp4",
    })
  })

  it("does not carry the internal provider query exemption through redirects", async () => {
    let requests = 0
    const endpoint = "https://cdn.syndication.twimg.com/tweet-result?token=x&id=123"
    await expect(fetchWithRedirects(endpoint, {
      lookup, timeoutMs: 200, maxRedirects: 1, userAgent: "test", accept: "application/json",
      trustedProviderEndpoint: endpoint,
      fetchImpl: async () => {
        requests++
        return new Response(null, { status: 302, headers: { location: "https://example.com/?token=private" } })
      },
    })).rejects.toMatchObject({ code: "invalid_url" })
    expect(requests).toBe(1)
  })
})
