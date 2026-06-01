import { afterEach, describe, expect, it } from "bun:test"
import { eq } from "drizzle-orm"

import { db, schema } from "@in/server/db"
import { processUrlPreview } from "@in/server/modules/urlPreview/processUrlPreview"
import {
  getFreshPreviewCache,
  upsertPreviewCache,
} from "@in/server/modules/urlPreview/cache"
import { setupTestLifecycle, testUtils } from "../setup"

const originalFetch = globalThis.fetch

describe("URL preview cache", () => {
  setupTestLifecycle()

  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  it("stores fresh metadata by normalized url and ignores expired rows", async () => {
    const now = new Date("2026-05-31T10:00:00Z")
    const cache = await upsertPreviewCache({
      now,
      photoId: null,
      metadata: {
        url: "https://example.com/article?utm_source=share&id=1",
        finalUrl: "https://example.com/article?id=1",
        siteName: "Example",
        title: "Example article",
        description: "A short preview",
        mediaType: "video",
        provider: "generic",
        author: "Inline",
        media: {
          kind: "embed",
          url: "https://example.com/embed/article",
          embedType: "iframe",
          width: 640,
          height: 360,
          duration: 42,
        },
        layout: {
          hasLargeMedia: true,
          showLargeMedia: true,
        },
      },
    })

    const fresh = await getFreshPreviewCache("https://example.com/article?id=1", now)
    expect(fresh?.id).toBe(cache.id)
    expect(fresh?.mediaType).toBe("video")
    expect(fresh?.mediaKind).toBe("embed")
    expect(fresh?.embedType).toBe("iframe")
    expect(fresh?.embedWidth).toBe(640)
    expect(fresh?.embedHeight).toBe(360)
    expect(fresh?.embedDuration).toBe(42)
    expect(fresh?.hasLargeMedia).toBe(true)
    expect(fresh?.showLargeMedia).toBe(true)

    await db
      .update(schema.urlPreviewCache)
      .set({ expiresAt: new Date(now.getTime() - 1_000) })
      .where(eq(schema.urlPreviewCache.id, cache.id))

    const expired = await getFreshPreviewCache("https://example.com/article?id=1", now)
    expect(expired).toBeNull()
  })

  it("does not cache urls rejected by the preview normalizer", async () => {
    await expect(
      upsertPreviewCache({
        photoId: null,
        metadata: {
          url: "https://example.com/oauth/callback?code=secret",
          finalUrl: "https://example.com/oauth/callback?code=secret",
          title: "Do not cache",
          provider: "generic",
        },
      }),
    ).rejects.toThrow("Cannot cache invalid URL preview URL")
  })

  it("does not mark typed media available when the backing media was not stored", async () => {
    const cache = await upsertPreviewCache({
      photoId: null,
      metadata: {
        url: "https://example.com/photo",
        finalUrl: "https://example.com/photo",
        title: "Image page",
        mediaType: "image",
        provider: "generic",
        media: {
          kind: "photo",
          url: "https://example.com/photo.jpg",
        },
      },
    })

    expect(cache.mediaType).toBe("image")
    expect(cache.mediaKind).toBeNull()
    expect(cache.photoId).toBeNull()
  })

  it("uses cache hits without fetching the url again", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("URL Preview Cache", ["preview-cache@example.com"])
    const user = users[0]
    if (!space || !user) {
      throw new Error("Failed to create cache test fixtures")
    }

    const chat = await testUtils.createChat(space.id, "Preview Thread", "thread", true, user.id)
    if (!chat) {
      throw new Error("Failed to create cache test chat")
    }

    const message = await testUtils.createTestMessage({
      chatId: chat.id,
      fromId: user.id,
      messageId: 1,
      text: "https://example.com/cached",
    })

    const cache = await upsertPreviewCache({
      photoId: null,
      metadata: {
        url: "https://example.com/cached",
        finalUrl: "https://example.com/cached",
        siteName: "Example",
        title: "Cached article",
        mediaType: "video",
        provider: "generic",
      },
    })

    let fetchCalls = 0
    globalThis.fetch = (async () => {
      fetchCalls += 1
      throw new Error("network fetch should not run for cache hits")
    }) as unknown as typeof fetch

    try {
      await processUrlPreview({
        message,
        previewUrl: "https://example.com/cached",
        chatId: chat.id,
        currentUserId: user.id,
        inputPeer: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } },
      })
    } finally {
      globalThis.fetch = originalFetch
    }

    const [preview] = await db.select().from(schema.urlPreview).where(eq(schema.urlPreview.cacheId, cache.id)).limit(1)
    if (!preview) {
      throw new Error("Expected preview row cloned from cache")
    }
    expect(fetchCalls).toBe(0)
    expect(preview.cacheId).toBe(cache.id)
    expect(preview.mediaType).toBe("video")

    const attachments = await db.select().from(schema.messageAttachments)
    expect(attachments).toHaveLength(1)
    expect(attachments[0]?.urlPreviewId).toBe(BigInt(preview.id))
  })
})
