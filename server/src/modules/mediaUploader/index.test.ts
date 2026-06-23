import { describe, expect, test } from "bun:test"
import type { RichMediaRef, RichMessage } from "@inline-chat/protocol/core"
import {
  type MediaFetch,
  type MediaUploaderDeps,
  resolveRichMediaPublicUrls,
} from "@in/server/modules/mediaUploader"
import type { RichMediaPublicUrlFailureStore } from "@in/server/modules/mediaUploader/publicUrlFailures"
import { richMediaDependencies } from "@in/server/modules/message/richText"

describe("mediaUploader", () => {
  test("resolves rich photo public URLs into internal photo ids", async () => {
    const files: File[] = []
    const deps = depsWith({
      fetch: async () => new Response(new Uint8Array([1, 2, 3]), { headers: { "content-type": "image/png" } }),
      photoCdnUrl: (fileUniqueId) => `https://api.inline.test/file?id=${fileUniqueId}`,
      uploadPhoto: async (file) => {
        files.push(file)
        return { fileUniqueId: "photo-file", photoId: 123 }
      },
    })
    const rich = photoMessage("https://example.com/chart.png")

    const result = await resolveRichMediaPublicUrls({ richText: rich, userId: 7 }, deps)
    const block = result.richText.blocks[0]
    const media = block?.block.oneofKind === "photo" ? block.block.photo.media?.media : undefined
    const ref = block?.block.oneofKind === "photo" ? block.block.photo.media : undefined

    expect(result.resolved).toBe(1)
    expect(result.failed).toBe(0)
    expect(media).toEqual({ oneofKind: "photoId", photoId: 123n })
    expect(ref?.fileUniqueId).toBe("photo-file")
    expect(ref?.cdnUrl).toBe("https://api.inline.test/file?id=photo-file")
    expect(files[0]?.name).toBe("chart.png")
    expect(files[0]?.type).toBe("image/png")
    expect(rich.blocks[0]?.block.oneofKind === "photo" ? rich.blocks[0].block.photo.media?.media.oneofKind : undefined).toBe("publicUrl")
  })

  test("accepts AVIF rich photo public URLs so modern image hosts do not degrade", async () => {
    const files: File[] = []
    const deps = depsWith({
      fetch: async () => new Response(new Uint8Array([1, 2, 3]), { headers: { "content-type": "image/avif" } }),
      uploadPhoto: async (file) => {
        files.push(file)
        return { fileUniqueId: "photo-file", photoId: 124 }
      },
    })
    const rich = photoMessage("https://example.com/chart.avif")

    const result = await resolveRichMediaPublicUrls({ richText: rich, userId: 7 }, deps)
    const block = result.richText.blocks[0]
    const media = block?.block.oneofKind === "photo" ? block.block.photo.media?.media : undefined

    expect(result.resolved).toBe(1)
    expect(result.failed).toBe(0)
    expect(media).toEqual({ oneofKind: "photoId", photoId: 124n })
    expect(files[0]?.name).toBe("chart.avif")
    expect(files[0]?.type).toBe("image/avif")
  })

  test("resolves rich video public URLs when metadata is present", async () => {
    const deps = depsWith({
      fetch: async () => new Response(new Uint8Array([1, 2, 3]), { headers: { "content-type": "video/mp4" } }),
      uploadVideo: async (file, metadata) => {
        expect(file.type).toBe("video/mp4")
        expect(metadata).toEqual({ width: 640, height: 360, duration: 12 })
        return { fileUniqueId: "video-file", cdnUrl: "https://cdn.inline.test/video.mp4", videoId: 456 }
      },
    })
    const rich: RichMessage = {
      blocks: [
        {
          blockId: "video",
          block: {
            oneofKind: "video",
            video: {
              media: {
                alt: "Clip",
                width: 640,
                height: 360,
                media: { oneofKind: "publicUrl", publicUrl: "https://example.com/clip.mp4" },
              },
              caption: [],
              duration: 12,
            },
          },
        },
      ],
      fallbackText: "Clip",
      version: 4,
    }

    const result = await resolveRichMediaPublicUrls({ richText: rich, userId: 7 }, deps)
    const block = result.richText.blocks[0]
    const media = block?.block.oneofKind === "video" ? block.block.video.media?.media : undefined
    const ref = block?.block.oneofKind === "video" ? block.block.video.media : undefined

    expect(result.resolved).toBe(1)
    expect(result.failed).toBe(0)
    expect(media).toEqual({ oneofKind: "videoId", videoId: 456n })
    expect(ref?.fileUniqueId).toBe("video-file")
    expect(ref?.cdnUrl).toBe("https://cdn.inline.test/video.mp4")
  })

  test("resolves rich document public URLs into internal document ids", async () => {
    const deps = depsWith({
      fetch: async () => new Response(new Uint8Array([1, 2, 3]), { headers: { "content-type": "application/pdf" } }),
      uploadDocument: async (file) => {
        expect(file.name).toBe("report.pdf")
        expect(file.type).toBe("application/pdf")
        return { fileUniqueId: "doc-file", cdnUrl: "https://cdn.inline.test/report.pdf", documentId: 789 }
      },
    })
    const rich: RichMessage = {
      blocks: [
        {
          blockId: "doc",
          block: {
            oneofKind: "document",
            document: {
              media: {
                alt: "Report",
                media: { oneofKind: "publicUrl", publicUrl: "https://example.com/report.pdf" },
              },
              caption: [],
            },
          },
        },
      ],
      fallbackText: "Report",
      version: 4,
    }

    const result = await resolveRichMediaPublicUrls({ richText: rich, userId: 7 }, deps)
    const block = result.richText.blocks[0]
    const media = block?.block.oneofKind === "document" ? block.block.document.media?.media : undefined
    const ref = block?.block.oneofKind === "document" ? block.block.document.media : undefined

    expect(result.resolved).toBe(1)
    expect(result.failed).toBe(0)
    expect(media).toEqual({ oneofKind: "documentId", documentId: 789n })
    expect(ref?.fileUniqueId).toBe("doc-file")
    expect(ref?.cdnUrl).toBe("https://cdn.inline.test/report.pdf")
  })

  test("resolves rich audio public URLs into internal voice ids", async () => {
    const deps = depsWith({
      fetch: async () => new Response(new Uint8Array([1, 2, 3]), { headers: { "content-type": "audio/ogg" } }),
      uploadVoice: async (file, metadata) => {
        expect(file.name).toBe("voice.ogg")
        expect(file.type).toBe("audio/ogg")
        expect(metadata.duration).toBe(12)
        expect(Array.from(metadata.waveform)).toEqual([128, 128, 128, 128])
        return { fileUniqueId: "voice-file", cdnUrl: "https://cdn.inline.test/voice.ogg", voiceId: 321 }
      },
    })
    const rich: RichMessage = {
      blocks: [
        {
          blockId: "audio",
          block: {
            oneofKind: "audio",
            audio: {
              media: {
                alt: "Voice",
                media: { oneofKind: "publicUrl", publicUrl: "https://example.com/voice.ogg" },
              },
              caption: [],
              duration: 12,
              title: "Voice",
            },
          },
        },
      ],
      fallbackText: "Voice",
      version: 4,
    }

    const result = await resolveRichMediaPublicUrls({ richText: rich, userId: 7 }, deps)
    const block = result.richText.blocks[0]
    const media = block?.block.oneofKind === "audio" ? block.block.audio.media?.media : undefined
    const ref = block?.block.oneofKind === "audio" ? block.block.audio.media : undefined

    expect(result.resolved).toBe(1)
    expect(result.failed).toBe(0)
    expect(media).toEqual({ oneofKind: "voiceId", voiceId: 321n })
    expect(ref?.fileUniqueId).toBe("voice-file")
    expect(ref?.cdnUrl).toBe("https://cdn.inline.test/voice.ogg")
  })

  test("resolves public media refs embedded in rich card blocks", async () => {
    let fetchCount = 0
    let uploadCount = 0
    const deps = depsWith({
      fetch: async () => {
        fetchCount += 1
        return new Response(new Uint8Array([1, 2, 3]), { headers: { "content-type": "image/png" } })
      },
      photoCdnUrl: (fileUniqueId) => `https://api.inline.test/file?id=${fileUniqueId}`,
      uploadPhoto: async () => {
        uploadCount += 1
        return { fileUniqueId: "photo-file", photoId: 123 }
      },
    })
    const rich = cardMediaMessage("https://example.com/card.png")

    expect(publicMediaDependencyCount(rich)).toBe(4)

    const result = await resolveRichMediaPublicUrls({ richText: rich, userId: 7 }, deps)
    const blocks = result.richText.blocks

    expect(fetchCount).toBe(1)
    expect(uploadCount).toBe(1)
    expect(result.resolved).toBe(4)
    expect(result.failed).toBe(0)
    expect(publicMediaDependencyCount(result.richText)).toBe(0)
    expect(blocks[0]?.block.oneofKind === "embed" ? blocks[0].block.embed.poster?.media : undefined).toEqual({
      oneofKind: "photoId",
      photoId: 123n,
    })
    expect(blocks[1]?.block.oneofKind === "embedPost" ? blocks[1].block.embedPost.authorPhoto?.media : undefined).toEqual({
      oneofKind: "photoId",
      photoId: 123n,
    })
    expect(blocks[2]?.block.oneofKind === "linkPreview" ? blocks[2].block.linkPreview.media?.media : undefined).toEqual({
      oneofKind: "photoId",
      photoId: 123n,
    })
    const collageItem = blocks[3]?.block.oneofKind === "collage" ? blocks[3].block.collage.items[0] : undefined
    expect(collageItem?.block.oneofKind === "photo" ? collageItem.block.photo.media?.media : undefined).toEqual({
      oneofKind: "photoId",
      photoId: 123n,
    })
  })

  test("strips public URLs and adds a source caption when resolution fails", async () => {
    const deps = depsWith({
      fetch: async () => new Response("", { status: 404 }),
    })
    const rich = photoMessage("https://example.com/missing.png")

    const result = await resolveRichMediaPublicUrls({ richText: rich, userId: 7 }, deps)
    const block = result.richText.blocks[0]

    expect(result.resolved).toBe(0)
    expect(result.failed).toBe(1)
    expect(block?.block.oneofKind).toBe("paragraph")
    expect(blockText(block)).toBe("Source: https://example.com/missing.png")
    expect(result.richText.fallbackText).toBe("Source: https://example.com/missing.png")
  })

  test("strips failed public media refs embedded in rich card blocks", async () => {
    const deps = depsWith({
      fetch: async () => new Response("", { status: 404 }),
    })
    const rich = cardMediaMessage("https://example.com/missing-card.png")

    expect(publicMediaDependencyCount(rich)).toBe(4)

    const result = await resolveRichMediaPublicUrls({ richText: rich, userId: 7 }, deps)
    const blocks = result.richText.blocks

    expect(result.resolved).toBe(0)
    expect(result.failed).toBe(4)
    expect(publicMediaDependencyCount(result.richText)).toBe(0)
    expect(blocks[0]?.block.oneofKind === "embed" ? blocks[0].block.embed.poster?.media.oneofKind : undefined).toBeUndefined()
    expect(blocks[1]?.block.oneofKind === "embedPost" ? blocks[1].block.embedPost.authorPhoto?.media.oneofKind : undefined).toBeUndefined()
    expect(blocks[2]?.block.oneofKind === "linkPreview" ? blocks[2].block.linkPreview.media?.media.oneofKind : undefined).toBeUndefined()
    const collageItem = blocks[3]?.block.oneofKind === "collage" ? blocks[3].block.collage.items[0] : undefined
    expect(collageItem?.block.oneofKind).toBe("paragraph")
    expect(blockText(collageItem)).toBe("Source: https://example.com/missing-card.png")
  })

  test("deduplicates repeated public URL uploads within one rich message", async () => {
    let fetchCount = 0
    let uploadCount = 0
    const deps = depsWith({
      fetch: async () => {
        fetchCount += 1
        return new Response(new Uint8Array([1, 2, 3]), { headers: { "content-type": "image/png" } })
      },
      photoCdnUrl: (fileUniqueId) => `https://api.inline.test/file?id=${fileUniqueId}`,
      uploadPhoto: async () => {
        uploadCount += 1
        return { fileUniqueId: "photo-file", photoId: 123 }
      },
    })
    const rich: RichMessage = {
      blocks: [
        photoBlock("a", "https://example.com/chart.png"),
        photoBlock("b", "https://example.com/chart.png"),
      ],
      fallbackText: "Chart",
      version: 4,
    }

    const result = await resolveRichMediaPublicUrls({ richText: rich, userId: 7 }, deps)
    const first = result.richText.blocks[0]
    const second = result.richText.blocks[1]
    const firstMedia = first?.block.oneofKind === "photo" ? first.block.photo.media?.media : undefined
    const secondMedia = second?.block.oneofKind === "photo" ? second.block.photo.media?.media : undefined
    const firstRef = first?.block.oneofKind === "photo" ? first.block.photo.media : undefined
    const secondRef = second?.block.oneofKind === "photo" ? second.block.photo.media : undefined

    expect(fetchCount).toBe(1)
    expect(uploadCount).toBe(1)
    expect(result.resolved).toBe(2)
    expect(result.failed).toBe(0)
    expect(firstMedia).toEqual({ oneofKind: "photoId", photoId: 123n })
    expect(secondMedia).toEqual({ oneofKind: "photoId", photoId: 123n })
    expect(firstRef?.fileUniqueId).toBe("photo-file")
    expect(secondRef?.fileUniqueId).toBe("photo-file")
    expect(firstRef?.cdnUrl).toBe("https://api.inline.test/file?id=photo-file")
    expect(secondRef?.cdnUrl).toBe("https://api.inline.test/file?id=photo-file")
  })

  test("deduplicates repeated public URL failures within one rich message", async () => {
    let fetchCount = 0
    const deps = depsWith({
      fetch: async () => {
        fetchCount += 1
        return new Response("", { status: 404 })
      },
    })
    const rich: RichMessage = {
      blocks: [
        photoBlock("a", "https://example.com/missing.png"),
        photoBlock("b", "https://example.com/missing.png"),
      ],
      fallbackText: "Missing",
      version: 4,
    }

    const result = await resolveRichMediaPublicUrls({ richText: rich, userId: 7 }, deps)
    const first = result.richText.blocks[0]
    const second = result.richText.blocks[1]

    expect(fetchCount).toBe(1)
    expect(result.resolved).toBe(0)
    expect(result.failed).toBe(2)
    expect(first?.block.oneofKind).toBe("paragraph")
    expect(second?.block.oneofKind).toBe("paragraph")
    expect(blockText(first)).toBe("Source: https://example.com/missing.png")
    expect(blockText(second)).toBe("Source: https://example.com/missing.png")
  })

  test("backs off repeated public URL failures across rich message resolution calls", async () => {
    let fetchCount = 0
    const failureStore = memoryFailureStore()
    const deps = depsWith({
      failureStore,
      fetch: async () => {
        fetchCount += 1
        return new Response("", { status: 404 })
      },
    })

    const first = await resolveRichMediaPublicUrls({ richText: photoMessage("https://example.com/missing.png"), userId: 7 }, deps)
    const second = await resolveRichMediaPublicUrls({ richText: photoMessage("https://example.com/missing.png"), userId: 7 }, deps)

    expect(fetchCount).toBe(1)
    expect(first.resolved).toBe(0)
    expect(first.failed).toBe(1)
    expect(second.resolved).toBe(0)
    expect(second.failed).toBe(1)
    expect(blockText(second.richText.blocks[0])).toBe("Source: https://example.com/missing.png")
  })

  test("scopes public URL failure backoff by media kind", async () => {
    let fetchCount = 0
    const url = "https://example.com/shared.pdf"
    const failureStore = memoryFailureStore()
    const deps = depsWith({
      failureStore,
      fetch: async () => {
        fetchCount += 1
        if (fetchCount === 1) {
          return new Response("", { status: 404 })
        }
        return new Response(new Uint8Array([1, 2, 3]), { headers: { "content-type": "application/pdf" } })
      },
      uploadDocument: async (file) => {
        expect(file.name).toBe("shared.pdf")
        expect(file.type).toBe("application/pdf")
        return { fileUniqueId: "doc-file", documentId: 789 }
      },
    })

    const failedPhoto = await resolveRichMediaPublicUrls({ richText: photoMessage(url), userId: 7 }, deps)
    const resolvedDocument = await resolveRichMediaPublicUrls({ richText: documentMessage(url), userId: 7 }, deps)
    const block = resolvedDocument.richText.blocks[0]
    const media = block?.block.oneofKind === "document" ? block.block.document.media?.media : undefined

    expect(fetchCount).toBe(2)
    expect(failedPhoto.failed).toBe(1)
    expect(resolvedDocument.resolved).toBe(1)
    expect(resolvedDocument.failed).toBe(0)
    expect(media).toEqual({ oneofKind: "documentId", documentId: 789n })
  })

  test("does not back off internal upload failures", async () => {
    let fetchCount = 0
    const failureStore = memoryFailureStore()
    const deps = depsWith({
      failureStore,
      fetch: async () => {
        fetchCount += 1
        return new Response(new Uint8Array([1, 2, 3]), { headers: { "content-type": "image/png" } })
      },
      uploadPhoto: async () => {
        throw new Error("database unavailable")
      },
    })

    await resolveRichMediaPublicUrls({ richText: photoMessage("https://example.com/chart.png"), userId: 7 }, deps)
    await resolveRichMediaPublicUrls({ richText: photoMessage("https://example.com/chart.png"), userId: 7 }, deps)

    expect(fetchCount).toBe(2)
    expect(failureStore.size()).toBe(0)
  })

  test("clears stale public URL failure state after a successful resolution", async () => {
    let clearCount = 0
    const failureStore = memoryFailureStore({
      clearFailure: async () => {
        clearCount += 1
      },
    })
    const deps = depsWith({
      failureStore,
      fetch: async () => new Response(new Uint8Array([1, 2, 3]), { headers: { "content-type": "image/png" } }),
      uploadPhoto: async () => ({ fileUniqueId: "photo-file", photoId: 123 }),
    })

    const result = await resolveRichMediaPublicUrls({ richText: photoMessage("https://example.com/chart.png"), userId: 7 }, deps)

    expect(result.resolved).toBe(1)
    expect(result.failed).toBe(0)
    expect(clearCount).toBe(1)
  })

  test("rejects non-image photo URLs before upload", async () => {
    let uploadCount = 0
    const deps = depsWith({
      fetch: async () => new Response("<html></html>", { headers: { "content-type": "text/html" } }),
      uploadPhoto: async () => {
        uploadCount += 1
        throw new Error("unexpected photo upload")
      },
    })
    const rich = photoMessage("https://example.com/page")

    const result = await resolveRichMediaPublicUrls({ richText: rich, userId: 7 }, deps)
    const block = result.richText.blocks[0]

    expect(uploadCount).toBe(0)
    expect(result.resolved).toBe(0)
    expect(result.failed).toBe(1)
    expect(block?.block.oneofKind).toBe("paragraph")
    expect(blockText(block)).toBe("Source: https://example.com/page")
  })

  test("rejects direct private IP URLs before fetch", async () => {
    let fetchCount = 0
    const deps = depsWith({
      fetch: async () => {
        fetchCount += 1
        throw new Error("unexpected fetch")
      },
    })
    const rich = photoMessage("https://127.0.0.1/private.png")

    const result = await resolveRichMediaPublicUrls({ richText: rich, userId: 7 }, deps)

    expect(fetchCount).toBe(0)
    expect(result.resolved).toBe(0)
    expect(result.failed).toBe(1)
    expect(result.richText.blocks).toEqual([])
    expect(result.richText.fallbackText).toBe("")
  })

  test("rejects DNS resolution to private addresses before fetch", async () => {
    let fetchCount = 0
    const deps = depsWith({
      lookup: async () => [{ address: "10.0.0.5", family: 4 }],
      fetch: async () => {
        fetchCount += 1
        throw new Error("unexpected fetch")
      },
    })
    const rich = photoMessage("https://example.com/private.png")

    const result = await resolveRichMediaPublicUrls({ richText: rich, userId: 7 }, deps)
    const block = result.richText.blocks[0]

    expect(fetchCount).toBe(0)
    expect(result.resolved).toBe(0)
    expect(result.failed).toBe(1)
    expect(block?.block.oneofKind).toBe("paragraph")
    expect(blockText(block)).toBe("Source: https://example.com/private.png")
  })

  test("rejects redirects to private targets before fetching the redirect target", async () => {
    let fetchCount = 0
    const deps = depsWith({
      fetch: async () => {
        fetchCount += 1
        return new Response(null, {
          status: 302,
          headers: { location: "https://127.0.0.1/final.png" },
        })
      },
      uploadPhoto: async () => {
        throw new Error("unexpected photo upload")
      },
    })
    const rich = photoMessage("https://example.com/start.png")

    const result = await resolveRichMediaPublicUrls({ richText: rich, userId: 7 }, deps)
    const block = result.richText.blocks[0]

    expect(fetchCount).toBe(1)
    expect(result.resolved).toBe(0)
    expect(result.failed).toBe(1)
    expect(block?.block.oneofKind).toBe("paragraph")
    expect(blockText(block)).toBe("Source: https://example.com/start.png")
  })

  test("follows safe redirects and names the uploaded file from the final URL", async () => {
    const fetched: string[] = []
    const deps = depsWith({
      fetch: async (input, init) => {
        fetched.push(String(input))
        expect(init?.redirect).toBe("manual")
        if (fetched.length === 1) {
          return new Response(null, {
            status: 302,
            headers: { location: "/assets/final.png" },
          })
        }
        return new Response(new Uint8Array([1, 2, 3]), { headers: { "content-type": "image/png" } })
      },
      uploadPhoto: async (file) => {
        expect(file.name).toBe("final.png")
        return { fileUniqueId: "photo-file", photoId: 123 }
      },
    })
    const rich = photoMessage("https://example.com/start")

    const result = await resolveRichMediaPublicUrls({ richText: rich, userId: 7 }, deps)
    const block = result.richText.blocks[0]
    const media = block?.block.oneofKind === "photo" ? block.block.photo.media?.media : undefined

    expect(fetched).toEqual(["https://example.com/start", "https://example.com/assets/final.png"])
    expect(result.resolved).toBe(1)
    expect(result.failed).toBe(0)
    expect(media).toEqual({ oneofKind: "photoId", photoId: 123n })
  })

  test("rejects URLs with embedded credentials before fetch", async () => {
    let fetchCount = 0
    const deps = depsWith({
      fetch: async () => {
        fetchCount += 1
        throw new Error("unexpected fetch")
      },
    })
    const rich = photoMessage("https://user:pass@example.com/private.png")

    const result = await resolveRichMediaPublicUrls({ richText: rich, userId: 7 }, deps)

    expect(fetchCount).toBe(0)
    expect(result.resolved).toBe(0)
    expect(result.failed).toBe(1)
    expect(result.richText.blocks).toEqual([])
    expect(result.richText.fallbackText).toBe("")
  })

  test("rejects oversized remote files from content length before upload", async () => {
    let uploadCount = 0
    const deps = depsWith({
      fetch: async () =>
        new Response(new Uint8Array([1, 2, 3]), {
          headers: {
            "content-type": "image/png",
            "content-length": String(41 * 1024 * 1024),
          },
        }),
      uploadPhoto: async () => {
        uploadCount += 1
        throw new Error("unexpected photo upload")
      },
    })
    const rich = photoMessage("https://example.com/large.png")

    const result = await resolveRichMediaPublicUrls({ richText: rich, userId: 7 }, deps)
    const block = result.richText.blocks[0]

    expect(uploadCount).toBe(0)
    expect(result.resolved).toBe(0)
    expect(result.failed).toBe(1)
    expect(block?.block.oneofKind).toBe("paragraph")
    expect(blockText(block)).toBe("Source: https://example.com/large.png")
  })
})

function photoMessage(url: string): RichMessage {
  return {
    blocks: [
      photoBlock("photo", url),
    ],
    fallbackText: "Chart",
    version: 4,
  }
}

function photoBlock(blockId: string, url: string): RichMessage["blocks"][number] {
  return {
    blockId,
    block: {
      oneofKind: "photo",
      photo: {
        media: {
          alt: "Chart",
          media: { oneofKind: "publicUrl", publicUrl: url },
        },
        caption: [],
      },
    },
  }
}

function documentMessage(url: string): RichMessage {
  return {
    blocks: [
      {
        blockId: "document",
        block: {
          oneofKind: "document",
          document: {
            media: {
              alt: "Document",
              media: { oneofKind: "publicUrl", publicUrl: url },
            },
            caption: [],
          },
        },
      },
    ],
    fallbackText: "Document",
    version: 4,
  }
}

function cardMediaMessage(url: string): RichMessage {
  return {
    blocks: [
      {
        blockId: "embed",
        block: {
          oneofKind: "embed",
          embed: {
            url: "https://example.com/embed",
            poster: publicPhotoRef(url),
            caption: [],
            fullWidth: false,
            allowScrolling: false,
          },
        },
      },
      {
        blockId: "embed-post",
        block: {
          oneofKind: "embedPost",
          embedPost: {
            url: "https://example.com/post",
            author: "Ada",
            authorPhoto: publicPhotoRef(url),
            blocks: [
              {
                blockId: "post-body",
                block: {
                  oneofKind: "paragraph",
                  paragraph: { text: [{ text: "Post", children: [], styles: [] }] },
                },
              },
            ],
            caption: [],
          },
        },
      },
      {
        blockId: "link-preview",
        block: {
          oneofKind: "linkPreview",
          linkPreview: {
            url: "https://example.com/article",
            title: "Article",
            media: publicPhotoRef(url),
            compact: false,
          },
        },
      },
      {
        blockId: "collage",
        block: {
          oneofKind: "collage",
          collage: {
            items: [photoBlock("collage-photo", url)],
            caption: [],
          },
        },
      },
    ],
    fallbackText: "Cards",
    version: 4,
  }
}

function publicPhotoRef(url: string): RichMediaRef {
  return {
    alt: "Card image",
    media: { oneofKind: "publicUrl", publicUrl: url },
  }
}

function blockText(block: RichMessage["blocks"][number] | undefined): string {
  if (block?.block.oneofKind === "paragraph") {
    return block.block.paragraph.text.map((node) => node.text).join("")
  }
  if (block?.block.oneofKind === "photo") {
    return block.block.photo.caption.map((node) => node.text).join("")
  }
  return ""
}

function publicMediaDependencyCount(rich: RichMessage): number {
  return richMediaDependencies(rich).filter((dep) => dep.kind === "public_url").length
}

function depsWith(overrides: Partial<MediaUploaderDeps>): MediaUploaderDeps {
  return {
    fetch: (async () => new Response("")) as MediaFetch,
    lookup: async () => [{ address: "93.184.216.34", family: 4 }],
    photoCdnUrl: () => null,
    uploadPhoto: async () => {
      throw new Error("unexpected photo upload")
    },
    uploadVideo: async () => {
      throw new Error("unexpected video upload")
    },
    uploadVoice: async () => {
      throw new Error("unexpected voice upload")
    },
    uploadDocument: async () => {
      throw new Error("unexpected document upload")
    },
    ...overrides,
  }
}

function memoryFailureStore(
  overrides: Partial<RichMediaPublicUrlFailureStore> & { size?: never } = {},
): RichMediaPublicUrlFailureStore & { size: () => number } {
  const failures = new Map<string, { failureCount: number; retryAfter: Date }>()
  return {
    async activeBackoff(input) {
      const row = failures.get(failureKey(input.kind, input.publicUrl))
      if (!row || row.retryAfter <= input.now) {
        return null
      }
      return row
    },
    async recordFailure(input) {
      const key = failureKey(input.kind, input.publicUrl)
      const failureCount = (failures.get(key)?.failureCount ?? 0) + 1
      failures.set(key, {
        failureCount,
        retryAfter: new Date(input.now.getTime() + 60_000),
      })
    },
    async clearFailure(input) {
      failures.delete(failureKey(input.kind, input.publicUrl))
    },
    size() {
      return failures.size
    },
    ...overrides,
  }
}

function failureKey(kind: string, publicUrl: string): string {
  return `${kind}\n${publicUrl}`
}
