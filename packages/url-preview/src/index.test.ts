import { describe, expect, it } from "bun:test"
import {
  extractPreviewUrl,
  extractPreviewUrls,
  fetchBinary,
  fetchUrlPreview,
  isFigmaUrl,
  isXStatusUrl,
  isYouTubeUrl,
  normalizePreviewUrl,
  normalizeYouTubeUrl,
  resolvePreviewLayout,
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

  it("allows signed Figma CDN thumbnail urls without allowing generic signed urls", async () => {
    const thumbnailUrl =
      "https://api-cdn.figma.com/resize/thumbnails/6f703233-dc0c-4b97-9dbf-403f0e0b823e?expiration=1783900800&signature=figma-test-signature&height=450&bucket=figma-alpha"
    expect(normalizePreviewUrl(thumbnailUrl)).toBe(thumbnailUrl)
    expect(normalizePreviewUrl("https://example.com/image.png?signature=secret")).toBeNull()

    const bytes = new Uint8Array([1, 2, 3])
    const fetchImpl: NonNullable<FetchBinaryOptions["fetchImpl"]> = async (url) => {
      expect(String(url)).toBe(thumbnailUrl)
      return new Response(bytes, { headers: { "content-type": "image/webp" } })
    }

    const binary = await fetchBinary(thumbnailUrl, { fetchImpl, lookup: publicLookup })
    expect(binary?.contentType).toBe("image/webp")
    expect(binary?.finalUrl).toBe(thumbnailUrl)
    expect(binary?.bytes).toEqual(bytes)
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

  it("resolves single-link large preview layout for configured origins", () => {
    expect(
      resolvePreviewLayout({
        url: "https://x.com/inline/status/123",
        hasCardContent: true,
        urlCount: 1,
      }),
    ).toEqual({
      hasLargeMedia: true,
      showLargeMedia: true,
    })
    expect(
      resolvePreviewLayout({
        url: "https://x.com/inline/status/123",
        hasCardContent: true,
        urlCount: 2,
      }),
    ).toEqual({
      hasLargeMedia: true,
      showLargeMedia: false,
    })
    expect(
      resolvePreviewLayout({
        url: "https://x.com/inline/status/123",
        urlCount: 1,
      }),
    ).toEqual({
      hasLargeMedia: false,
      showLargeMedia: false,
    })
    expect(
      resolvePreviewLayout({
        url: "https://x.com/inline/status/123",
        hasPhoto: true,
        urlCount: 1,
      }),
    ).toEqual({
      hasLargeMedia: true,
      showLargeMedia: true,
    })
    expect(
      resolvePreviewLayout({
        url: "https://twitter.com/inline/status/123",
        hasPhoto: true,
        urlCount: 2,
      }),
    ).toEqual({
      hasLargeMedia: true,
      showLargeMedia: false,
    })
    expect(
      resolvePreviewLayout({
        url: "https://www.youtube.com/watch?v=abcDEF12345",
        provider: "youtube",
        mediaKind: "embed",
        urlCount: 1,
      }),
    ).toEqual({
      hasLargeMedia: true,
      showLargeMedia: true,
    })
    expect(
      resolvePreviewLayout({
        url: "https://www.figma.com/design/x3NE1TYyRgBtNrtldA4SLE/elevator-guide",
        provider: "figma",
        mediaKind: "photo",
        hasPhoto: true,
        urlCount: 1,
      }),
    ).toEqual({
      hasLargeMedia: true,
      showLargeMedia: true,
    })
    expect(
      resolvePreviewLayout({
        url: "https://www.figma.com/design/x3NE1TYyRgBtNrtldA4SLE/elevator-guide",
        provider: "figma",
        mediaKind: "photo",
        hasPhoto: true,
        urlCount: 2,
      }),
    ).toEqual({
      hasLargeMedia: true,
      showLargeMedia: false,
    })
  })

  it("preserves existing layout hints for unconfigured origins", () => {
    expect(
      resolvePreviewLayout({
        url: "https://video.example.com/watch/1",
        hasLargeMedia: true,
        showLargeMedia: true,
        urlCount: 2,
      }),
    ).toEqual({
      hasLargeMedia: true,
      showLargeMedia: true,
    })
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

  it("uses Figma oEmbed thumbnails as static image previews", async () => {
    const figmaUrl = "https://www.figma.com/design/x3NE1TYyRgBtNrtldA4SLE/elevator-guide?node-id=0-1&t=share"
    const thumbnailUrl =
      "https://api-cdn.figma.com/resize/thumbnails/6f703233-dc0c-4b97-9dbf-403f0e0b823e?expiration=1783900800&signature=figma-test-signature&height=450&bucket=figma-alpha"
    const fetchedUrls: string[] = []
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      fetchedUrls.push(String(url))
      return Response.json({
        version: "1.0",
        type: "rich",
        title: "elevator guide",
        key: "x3NE1TYyRgBtNrtldA4SLE",
        url: figmaUrl,
        provider_name: "Figma",
        provider_url: "https://www.figma.com",
        width: 800,
        height: 450,
        html: '<iframe src="https://embed.figma.com/design/x3NE1TYyRgBtNrtldA4SLE/elevator-guide"></iframe>',
        thumbnail_url: thumbnailUrl,
        thumbnail_width: 317,
        thumbnail_height: 450,
      })
    }

    expect(isFigmaUrl(figmaUrl)).toBe(true)
    const preview = await fetchUrlPreview(figmaUrl, { fetchImpl, lookup: publicLookup })
    const endpoint = new URL(fetchedUrls[0] ?? "")

    expect(`${endpoint.origin}${endpoint.pathname}`).toBe("https://www.figma.com/api/oembed")
    expect(endpoint.searchParams.get("url")).toBe(figmaUrl)
    expect(preview).toMatchObject({
      provider: "figma",
      siteName: "Figma",
      title: "elevator guide",
      finalUrl: figmaUrl,
      imageUrl: thumbnailUrl,
      mediaType: "image",
      media: {
        kind: "photo",
        url: thumbnailUrl,
        width: 317,
        height: 450,
      },
      layout: {
        hasLargeMedia: true,
        showLargeMedia: false,
      },
    })
    expect(preview?.duration).toBeUndefined()
  })

  it("does not treat fallback Figma Twitter-player metadata as video", async () => {
    const figmaUrl = "https://www.figma.com/design/x3NE1TYyRgBtNrtldA4SLE/elevator-guide?node-id=0-1&t=share"
    const thumbnailUrl =
      "https://www.figma.com/file/x3NE1TYyRgBtNrtldA4SLE/thumbnail?node-id=0-1&in-better-link-exp=true&t=share"
    const fetchedUrls: string[] = []
    const html = `
      <html>
        <head>
          <meta name="twitter:card" content="player">
          <meta name="twitter:title" content="elevator guide">
          <meta name="twitter:player" content="https://www.figma.com/embed?embed_host=twitter&amp;url=https://www.figma.com/design/x3NE1TYyRgBtNrtldA4SLE/elevator-guide">
          <meta name="twitter:player:width" content="800">
          <meta name="twitter:player:height" content="450">
          <meta property="og:title" content="Figma">
          <meta property="og:site_name" content="Figma">
          <meta property="og:description" content="Created with Figma">
          <meta property="og:image" content="${thumbnailUrl}">
          <meta property="og:type" content="article">
        </head>
      </html>
    `
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      const urlString = String(url)
      fetchedUrls.push(urlString)
      if (urlString.startsWith("https://www.figma.com/api/oembed?")) {
        return new Response("unavailable", { status: 500 })
      }

      expect(urlString).toBe(figmaUrl)
      return new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } })
    }

    const preview = await fetchUrlPreview(figmaUrl, { fetchImpl, lookup: publicLookup })

    expect(fetchedUrls).toHaveLength(2)
    expect(preview).toMatchObject({
      provider: "generic",
      siteName: "Figma",
      title: "Figma",
      description: "Created with Figma",
      imageUrl: thumbnailUrl,
      mediaType: "article",
    })
    expect(preview?.media).toBeUndefined()
    expect(preview?.duration).toBeUndefined()
  })

  it("keeps X profile images out of primary preview media", async () => {
    expect(isXStatusUrl("https://mobile.twitter.com/inline/status/123")).toBe(true)

    const html = `
      <html>
        <head>
          <meta property="og:title" content="Inline (@inline) on X">
          <meta property="og:description" content="A post without attached media">
          <meta property="og:image" content="https://pbs.twimg.com/profile_images/123/avatar_normal.jpg">
        </head>
      </html>
    `
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async () =>
      new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } })

    const preview = await fetchUrlPreview("https://x.com/inline/status/123", { fetchImpl, lookup: publicLookup })

    expect(preview?.provider).toBe("x")
    expect(preview?.title).toBe("Inline (@inline) on X")
    expect(preview?.author).toBe("Inline")
    expect(preview?.imageUrl).toBeUndefined()
    expect(preview?.authorPhotoUrl).toBe("https://pbs.twimg.com/profile_images/123/avatar_normal.jpg")
    expect(preview?.media).toBeUndefined()
    expect(preview?.layout).toEqual({
      hasLargeMedia: true,
      showLargeMedia: true,
    })
  })

  it("prefers X tweet media over the author profile image", async () => {
    const html = `
      <html>
        <head>
          <meta property="og:title" content="Inline on X">
          <meta property="og:image" content="https://pbs.twimg.com/profile_images/123/avatar_normal.jpg">
          <meta property="og:image" content="https://pbs.twimg.com/media/GQx_example.jpg?format=jpg&amp;name=large">
          <meta property="og:type" content="photo">
          <meta property="og:image:width" content="1200">
          <meta property="og:image:height" content="675">
        </head>
      </html>
    `
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async () =>
      new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } })

    const preview = await fetchUrlPreview("https://twitter.com/inline/status/123", { fetchImpl, lookup: publicLookup })

    expect(preview?.imageUrl).toBe("https://pbs.twimg.com/media/GQx_example.jpg?format=jpg&name=large")
    expect(preview?.authorPhotoUrl).toBe("https://pbs.twimg.com/profile_images/123/avatar_normal.jpg")
    expect(preview?.media).toEqual({
      kind: "photo",
      url: "https://pbs.twimg.com/media/GQx_example.jpg?format=jpg&name=large",
      width: 1200,
      height: 675,
    })
  })

  it("extracts X tweet video media from syndication payloads", async () => {
    let fetchedUrl = ""
    const payload = {
      __typename: "Tweet",
      text: "Maybe you weren't meant to have a boss.\n\nRead more https://t.co/ordinary https://t.co/x1KlUklH6L",
      user: {
        name: "Mo Rajabi",
        screen_name: "morajabi",
        profile_image_url_https: "https://pbs.twimg.com/profile_images/1928904602751057921/5PjsTnNE_normal.jpg",
      },
      entities: {
        media: [
          {
            url: "https://t.co/x1KlUklH6L",
          },
        ],
      },
      mediaDetails: [
        {
          url: "https://t.co/x1KlUklH6L",
          media_url_https: "https://pbs.twimg.com/amplify_video_thumb/2070457164825591808/img/7LL-BHEYURHK8Y74.jpg",
          original_info: { width: 1714, height: 964 },
          type: "video",
          video_info: {
            duration_millis: 19_201,
            variants: [
              {
                content_type: "application/x-mpegURL",
                url: "https://video.twimg.com/amplify_video/2070457164825591808/pl/kILfVVgY3F_XFHwH.m3u8",
              },
              {
                bitrate: 832_000,
                content_type: "video/mp4",
                url: "https://video.twimg.com/amplify_video/2070457164825591808/vid/avc1/640x360/vm1IlIxsz-SnoTMr.mp4",
              },
              {
                bitrate: 10_368_000,
                content_type: "video/mp4",
                url: "https://video.twimg.com/amplify_video/2070457164825591808/vid/avc1/1714x964/8SoDDtHMJD5h2aIH.mp4",
              },
            ],
          },
        },
      ],
    }
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      fetchedUrl = String(url)
      return new Response(JSON.stringify(payload), {
        headers: { "content-type": "application/json" },
      })
    }

    const preview = await fetchUrlPreview("https://x.com/morajabi/status/2070457314524459100", {
      fetchImpl,
      lookup: publicLookup,
    })

    expect(fetchedUrl).toContain("cdn.syndication.twimg.com/tweet-result")
    expect(fetchedUrl).toContain("id=2070457314524459100")
    expect(preview).toMatchObject({
      provider: "x",
      siteName: "X",
      title: "Mo Rajabi (@morajabi) on X",
      author: "Mo Rajabi",
      description: "Maybe you weren't meant to have a boss.\n\nRead more https://t.co/ordinary",
      imageUrl: "https://pbs.twimg.com/amplify_video_thumb/2070457164825591808/img/7LL-BHEYURHK8Y74.jpg",
      authorPhotoUrl: "https://pbs.twimg.com/profile_images/1928904602751057921/5PjsTnNE_200x200.jpg",
      duration: 19,
      mediaType: "video",
      media: {
        kind: "external_video",
        url: "https://video.twimg.com/amplify_video/2070457164825591808/vid/avc1/1714x964/8SoDDtHMJD5h2aIH.mp4",
        mimeType: "video/mp4",
        width: 1714,
        height: 964,
        duration: 19,
      },
      layout: {
        hasLargeMedia: true,
        showLargeMedia: true,
      },
    })
  })

  it("extracts text-only X tweet cards and preserves newlines", async () => {
    let fetchedUrl = ""
    const payload = {
      __typename: "Tweet",
      text: "stream starts soon\nnew video after\n\nsee you there",
      user: {
        name: "Ludwig",
        screen_name: "ludwig",
        profile_image_url_https: "https://pbs.twimg.com/profile_images/123/avatar_normal.jpg",
      },
      entities: {},
      mediaDetails: [],
    }
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      fetchedUrl = String(url)
      return new Response(JSON.stringify(payload), {
        headers: { "content-type": "application/json" },
      })
    }

    const preview = await fetchUrlPreview("https://x.com/ludwig/status/2072005832716292415?s=20", {
      fetchImpl,
      lookup: publicLookup,
    })

    expect(fetchedUrl).toContain("id=2072005832716292415")
    expect(preview).toMatchObject({
      provider: "x",
      siteName: "X",
      title: "Ludwig (@ludwig) on X",
      author: "Ludwig",
      description: "stream starts soon\nnew video after\n\nsee you there",
      authorPhotoUrl: "https://pbs.twimg.com/profile_images/123/avatar_200x200.jpg",
      layout: {
        hasLargeMedia: true,
        showLargeMedia: true,
      },
    })
    expect(preview?.imageUrl).toBeUndefined()
    expect(preview?.media).toBeUndefined()
  })

  it("retains normal X tweet text beyond the old compact-card storage limit", async () => {
    const fullText =
      "A Brown professor gave his students a take-home midterm exam. After suspecting many cheated using AI, he made the final in-person. The orange dots are the midterm scores and the gray dots are the final scores. Looks like all but 3 cheated on the midterm."
    const payload = {
      __typename: "Tweet",
      text: `${fullText} https://t.co/hekcGsz76h`,
      user: {
        name: "Paul Graham",
        screen_name: "paulg",
        profile_image_url_https: "https://pbs.twimg.com/profile_images/1824002576/pg-railsconf_normal.jpg",
      },
      entities: {
        media: [
          {
            url: "https://t.co/hekcGsz76h",
          },
        ],
      },
      mediaDetails: [
        {
          url: "https://t.co/hekcGsz76h",
          media_url_https: "https://pbs.twimg.com/media/HMv9NYTWIAAcB4w.jpg",
          original_info: { width: 621, height: 1121 },
          type: "photo",
        },
      ],
    }
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async () =>
      new Response(JSON.stringify(payload), {
        headers: { "content-type": "application/json" },
      })

    const preview = await fetchUrlPreview("https://x.com/paulg/status/2075031014628311236", {
      fetchImpl,
      lookup: publicLookup,
    })

    expect(preview?.description).toBe(fullText)
    expect(preview?.description).not.toContain("…")
  })

  it("retains multiline X tweet text beyond the old compact-card storage limit", async () => {
    const fullText = [
      "The first paragraph has enough detail to prove this text is stored for the large card instead of the old compact card limit.",
      "",
      "The second paragraph should stay separated by a blank line, with the final sentence still visible after the media URL is removed.",
      "The third line should remain a real newline too.",
    ].join("\n")
    const payload = {
      __typename: "Tweet",
      text: `${fullText}\nhttps://t.co/multilineMedia`,
      user: {
        name: "Inline",
        screen_name: "inline",
        profile_image_url_https: "https://pbs.twimg.com/profile_images/123/avatar_normal.jpg",
      },
      entities: {
        media: [
          {
            url: "https://t.co/multilineMedia",
          },
        ],
      },
      mediaDetails: [
        {
          url: "https://t.co/multilineMedia",
          media_url_https: "https://pbs.twimg.com/media/multiline.jpg",
          original_info: { width: 1200, height: 800 },
          type: "photo",
        },
      ],
    }
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async () =>
      new Response(JSON.stringify(payload), {
        headers: { "content-type": "application/json" },
      })

    const preview = await fetchUrlPreview("https://x.com/inline/status/2075031014628311237", {
      fetchImpl,
      lookup: publicLookup,
    })

    expect(preview?.description).toBe(fullText)
    expect(preview?.description).toContain("\n\n")
    expect(preview?.description).toContain("\nThe third line")
  })

  it("uses logged-out X HTML to fill note tweet text beyond the syndication compatibility body", async () => {
    const compatibilityText = [
      "I don't read hacker News much, someone told me my reMarkable project made it there.",
      "",
      "I don't recommend reading the comments.",
      "",
      "While it does not affect me emotionally, I was pretty baffle at how negative and suspicions people are. I have a hard time seeing the benefits of being",
    ].join("\n")
    const fullText = `${compatibilityText} soo gloomy :o`
    const payload = {
      __typename: "Tweet",
      text: `${compatibilityText} https://t.co/v9AxXkTbpv`,
      note_tweet: {
        id: "Tm90ZVR3ZWV0UmVzdWx0czoyMDc0NTMxMTI5NTcxMzUyNTc2",
      },
      user: {
        name: "Maxime Rivest",
        screen_name: "MaximeRivest",
        profile_image_url_https: "https://pbs.twimg.com/profile_images/123/avatar_normal.jpg",
      },
      entities: {
        media: [
          {
            url: "https://t.co/v9AxXkTbpv",
          },
        ],
      },
      mediaDetails: [
        {
          url: "https://t.co/v9AxXkTbpv",
          media_url_https: "https://pbs.twimg.com/media/HMo3EW_WMAAh2le.jpg",
          original_info: { width: 1200, height: 1116 },
          type: "photo",
        },
      ],
    }
    const encodedFullText = fullText.replaceAll("'", "&#x27;")
    const html = `
      <html>
        <body>
          <div class="flex flex-col gap-3">
            <div dir="auto" class='font-chirp max-w-full whitespace-pre-wrap break-words text-text text-body font-normal'>
              <span class="font-chirp max-w-full whitespace-pre-wrap break-words text-inherit text-[length:inherit] font-normal">${encodedFullText}</span>
            </div>
          </div>
        </body>
      </html>
    `
    const fetchedUrls: string[] = []
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      const urlString = String(url)
      fetchedUrls.push(urlString)
      if (urlString.includes("cdn.syndication.twimg.com/tweet-result")) {
        return new Response(JSON.stringify(payload), {
          headers: { "content-type": "application/json" },
        })
      }

      return new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } })
    }

    const preview = await fetchUrlPreview("https://x.com/MaximeRivest/status/2074531129646776401", {
      fetchImpl,
      lookup: publicLookup,
    })

    expect(fetchedUrls).toHaveLength(2)
    expect(fetchedUrls[0]).toContain("cdn.syndication.twimg.com/tweet-result")
    expect(fetchedUrls[1]).toBe("https://x.com/i/status/2074531129646776401")
    expect(preview?.description).toBe(fullText)
    expect(preview?.description).toContain("\n\n")
    expect(preview?.description).toContain("being soo gloomy :o")
  })

  it("decodes html entities in generic metadata", async () => {
    const html = `
      <html>
        <head>
          <meta property="og:site_name" content="Facebook &amp; Video">
          <meta property="og:title" content="&#x1f534; &#x6b63;&#x5728;&#x76f4;&#x64ad;&#xff01;Amy &#x5e36;&#x4f60;">
          <meta name="description" content="Fish &amp; chips &quot;safe&quot; &#169;">
          <meta property="og:image" content="/preview.png?x=1&amp;y=2">
        </head>
      </html>
    `
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async () =>
      new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } })

    const preview = await fetchUrlPreview("https://example.com/post", { fetchImpl, lookup: publicLookup })

    expect(preview?.siteName).toBe("Facebook & Video")
    expect(preview?.title).toBe("\u{1f534} \u6b63\u5728\u76f4\u64ad\uff01Amy \u5e36\u4f60")
    expect(preview?.description).toBe('Fish & chips "safe" \u00a9')
    expect(preview?.imageUrl).toBe("https://example.com/preview.png?x=1&y=2")
  })

  it("decodes html entities in fallback titles", async () => {
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async () =>
      new Response("<html><head><title>Tom &amp; Jerry &#x1f431;</title></head></html>", {
        headers: { "content-type": "text/html" },
      })

    const preview = await fetchUrlPreview("https://example.com/title", { fetchImpl, lookup: publicLookup })

    expect(preview?.title).toBe("Tom & Jerry \u{1f431}")
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

  it("detects direct video files and reads bounded mp4 duration metadata", async () => {
    const moov = mp4Box("moov", mp4MvhdBox({ timescale: 1_000, duration: 3_723_000 }))
    const fetchedRanges: string[] = []
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (_url, init) => {
      const range = new Headers(init?.headers).get("Range")
      if (!range) {
        return new Response(new Uint8Array(), {
          headers: {
            "content-type": "video/mp4",
            "content-length": String(8 * 1024 * 1024),
          },
        })
      }

      fetchedRanges.push(range)
      if (range.startsWith("bytes=0-")) {
        return new Response(mp4Box("ftyp", new Uint8Array([1, 2, 3, 4])), {
          status: 206,
          headers: {
            "content-type": "video/mp4",
            "content-range": "bytes 0-11/8388608",
          },
        })
      }

      return new Response(moov, {
        status: 206,
        headers: {
          "content-type": "video/mp4",
          "content-range": `bytes ${8 * 1024 * 1024 - moov.length}-${8 * 1024 * 1024 - 1}/8388608`,
        },
      })
    }

    const preview = await fetchUrlPreview("https://example.com/video.mp4", { fetchImpl, lookup: publicLookup })

    expect(fetchedRanges).toEqual(["bytes=0-262143", "bytes=-4194304"])
    expect(preview).toMatchObject({
      provider: "generic",
      siteName: "example.com",
      title: "video.mp4",
      duration: 3_723,
      mediaType: "video",
      media: {
        kind: "external_video",
        url: "https://example.com/video.mp4",
        mimeType: "video/mp4",
        duration: 3_723,
      },
      layout: {
        hasLargeMedia: true,
        showLargeMedia: true,
      },
    })
    expect(preview?.imageUrl).toBeUndefined()
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
    expect(isYouTubeUrl("https://www.youtube-nocookie.com/embed/abcDEF12345")).toBe(true)
    expect(normalizeYouTubeUrl("https://www.youtube.com/shorts/abcDEF12345?feature=share")).toBe(
      "https://www.youtube.com/watch?v=abcDEF12345",
    )
    expect(normalizeYouTubeUrl("https://www.youtube-nocookie.com/embed/abcDEF12345")).toBe(
      "https://www.youtube.com/watch?v=abcDEF12345",
    )

    const fetchedUrls: string[] = []
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      const urlString = String(url)
      fetchedUrls.push(urlString)
      if (!urlString.startsWith("https://www.youtube.com/oembed?")) {
        expect(urlString).toBe("https://www.youtube.com/watch?v=abcDEF12345")
        return new Response(
          `<html><head></head><body>
            <script>
              var ytInitialData = {"videoSecondaryInfoRenderer":{"owner":{"videoOwnerRenderer":{"thumbnail":{"thumbnails":[
                {"url":"https://yt3.ggpht.com/channel-avatar=s48-c-k-c0x00ffffff-no-rj","width":48,"height":48},
                {"url":"https://yt3.ggpht.com/channel-avatar=s176-c-k-c0x00ffffff-no-rj","width":176,"height":176}
              ]}}}}};
            </script>
          </body></html>`,
          { headers: { "content-type": "text/html; charset=utf-8" } },
        )
      }

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
      imageUrl: "https://i.ytimg.com/vi/abcDEF12345/mqdefault.jpg",
      authorPhotoUrl: "https://yt3.ggpht.com/channel-avatar=s176-c-k-c0x00ffffff-no-rj",
      mediaType: "video",
      media: {
        kind: "embed",
        url: "https://www.youtube.com/embed/abcDEF12345",
        embedType: "iframe",
        width: 480,
        height: 270,
      },
    })
    expect(fetchedUrls).toHaveLength(2)
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

  it("keeps YouTube channel avatars out of primary preview media", async () => {
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      const urlString = String(url)
      if (urlString.startsWith("https://www.youtube.com/oembed?")) {
        return new Response("forbidden", { status: 403, headers: { "content-type": "text/html" } })
      }

      return new Response(
        `<html><head>
          <meta property="og:title" content="Page title">
          <meta property="og:image" content="https://yt3.ggpht.com/channel-avatar=s88-c-k-c0x00ffffff-no-rj">
          <meta property="og:image" content="https://i.ytimg.com/vi/abcDEF12345/maxresdefault.jpg">
        </head></html>`,
        { headers: { "content-type": "text/html" } },
      )
    }

    const preview = await fetchUrlPreview("https://www.youtube.com/watch?v=abcDEF12345", {
      fetchImpl,
      lookup: publicLookup,
    })

    expect(preview?.provider).toBe("youtube")
    expect(preview?.imageUrl).toBe("https://i.ytimg.com/vi/abcDEF12345/maxresdefault.jpg")
    expect(preview?.authorPhotoUrl).toBe("https://yt3.ggpht.com/channel-avatar=s88-c-k-c0x00ffffff-no-rj")
    expect(preview?.media).toEqual({
      kind: "embed",
      url: "https://www.youtube.com/embed/abcDEF12345",
      embedType: "iframe",
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

  it("falls back to YouTube page metadata when oEmbed omits title", async () => {
    const fetchImpl: NonNullable<FetchUrlPreviewOptions["fetchImpl"]> = async (url) => {
      const urlString = String(url)
      if (urlString.startsWith("https://www.youtube.com/oembed?")) {
        return Response.json({
          author_name: "Inline",
          thumbnail_url: "https://i.ytimg.com/vi/abcDEF12345/hqdefault.jpg",
        })
      }

      return new Response(
        `<html><head>
          <meta property="og:title" content="Recovered title">
          <meta property="og:image" content="https://i.ytimg.com/vi/abcDEF12345/maxresdefault.jpg">
        </head></html>`,
        { headers: { "content-type": "text/html" } },
      )
    }

    const preview = await fetchUrlPreview("https://www.youtube.com/watch?v=abcDEF12345", {
      fetchImpl,
      lookup: publicLookup,
    })

    expect(preview?.title).toBe("Recovered title")
    expect(preview?.imageUrl).toBe("https://i.ytimg.com/vi/abcDEF12345/maxresdefault.jpg")
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
      imageUrl: "https://i.ytimg.com/vi/abcDEF12345/mqdefault.jpg",
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
      imageUrl: "https://i.ytimg.com/vi/abcDEF12345/mqdefault.jpg",
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

function mp4MvhdBox(input: { timescale: number; duration: number }): Uint8Array {
  const payload = new Uint8Array(100)
  writeUint32(payload, 12, input.timescale)
  writeUint32(payload, 16, input.duration)
  return mp4Box("mvhd", payload)
}

function mp4Box(type: string, payload: Uint8Array): Uint8Array {
  const bytes = new Uint8Array(payload.length + 8)
  writeUint32(bytes, 0, bytes.length)
  bytes[4] = type.charCodeAt(0)
  bytes[5] = type.charCodeAt(1)
  bytes[6] = type.charCodeAt(2)
  bytes[7] = type.charCodeAt(3)
  bytes.set(payload, 8)
  return bytes
}

function writeUint32(bytes: Uint8Array, offset: number, value: number) {
  bytes[offset] = (value >>> 24) & 0xff
  bytes[offset + 1] = (value >>> 16) & 0xff
  bytes[offset + 2] = (value >>> 8) & 0xff
  bytes[offset + 3] = value & 0xff
}
