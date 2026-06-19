import { afterEach, describe, expect, it } from "bun:test"
import { and, eq } from "drizzle-orm"

import { db, schema } from "@in/server/db"
import { MessageModel } from "@in/server/db/models/messages"
import { addSpaceUrlPreviewExclusion } from "@in/server/functions/space.urlPreviewExclusions"
import { encrypt } from "@in/server/modules/encryption/encryption"
import { isSpaceUrlPreviewExcluded } from "@in/server/modules/urlPreview/exclusions"
import { getPreviewRoutesFromMessage, processUrlPreview } from "@in/server/modules/urlPreview/processUrlPreview"
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
        siteName: "Facebook &amp; Video",
        title: "&#x1f534; &#x6b63;&#x5728;&#x76f4;&#x64ad;&#xff01;Amy &#x5e36;&#x4f60;",
        description: "Fish &amp; chips &quot;safe&quot; &#169;",
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

    const attachments = await db._query.messageAttachments.findMany({ with: { linkEmbed: true } })
    expect(attachments).toHaveLength(1)
    expect(attachments[0]?.urlPreviewId).toBe(BigInt(preview.id))

    const [attachment] = MessageModel.processAttachments(attachments)
    expect(attachment?.linkEmbed?.siteName).toBe("Facebook & Video")
    expect(attachment?.linkEmbed?.title).toBe("\u{1f534} \u6b63\u5728\u76f4\u64ad\uff01Amy \u5e36\u4f60")
    expect(attachment?.linkEmbed?.description).toBe('Fish & chips "safe" \u00a9')
  })

  it("skips excluded space URL previews before fetch or cache work", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("URL Preview Exclusion", ["preview-excluded@example.com"])
    const user = users[0]
    if (!space || !user) {
      throw new Error("Failed to create exclusion test fixtures")
    }

    const chat = await testUtils.createChat(space.id, "Preview Thread", "thread", true, user.id)
    if (!chat) {
      throw new Error("Failed to create exclusion test chat")
    }

    const message = await testUtils.createTestMessage({
      chatId: chat.id,
      fromId: user.id,
      messageId: 1,
      text: "https://secure.example.com/private/page",
    })

    await db.insert(schema.spaceUrlPreviewExclusions).values({
      spaceId: space.id,
      host: "secure.example.com",
      pathPrefix: "/private",
      createdBy: user.id,
    })

    expect(await isSpaceUrlPreviewExcluded({ spaceId: space.id, url: "https://secure.example.com/private/page" })).toBe(
      true,
    )
    expect(await isSpaceUrlPreviewExcluded({ spaceId: space.id, url: "https://example.com/private/page" })).toBe(false)
    expect(await isSpaceUrlPreviewExcluded({ spaceId: space.id, url: "https://secure.example.com/public/page" })).toBe(
      false,
    )

    let fetchCalls = 0
    globalThis.fetch = (async () => {
      fetchCalls += 1
      throw new Error("network fetch should not run for excluded previews")
    }) as unknown as typeof fetch

    try {
      await processUrlPreview({
        message,
        previewUrl: "https://secure.example.com/private/page",
        chatId: chat.id,
        spaceId: space.id,
        currentUserId: user.id,
        inputPeer: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } },
      })
    } finally {
      globalThis.fetch = originalFetch
    }

    const attachments = await db.select().from(schema.messageAttachments)
    expect(fetchCalls).toBe(0)
    expect(attachments).toHaveLength(0)
  })

  it("adds an exclusion and removes matching previews from the current message", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("URL Preview Cleanup", ["preview-cleanup@example.com"])
    const user = users[0]
    if (!space || !user) {
      throw new Error("Failed to create cleanup test fixtures")
    }
    await db
      .update(schema.members)
      .set({ role: "owner" })
      .where(and(eq(schema.members.spaceId, space.id), eq(schema.members.userId, user.id)))

    const chat = await testUtils.createChat(space.id, "Preview Thread", "thread", true, user.id)
    if (!chat) {
      throw new Error("Failed to create cleanup test chat")
    }

    const message = await testUtils.createTestMessage({
      chatId: chat.id,
      fromId: user.id,
      messageId: 1,
      text: "https://private.example.com/dashboard",
    })

    await upsertPreviewCache({
      photoId: null,
      metadata: {
        url: "https://private.example.com/dashboard",
        finalUrl: "https://private.example.com/dashboard",
        siteName: "Private",
        title: "Dashboard",
        provider: "generic",
      },
    })

    await processUrlPreview({
      message,
      previewUrl: "https://private.example.com/dashboard",
      chatId: chat.id,
      spaceId: space.id,
      currentUserId: user.id,
      inputPeer: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } },
    })

    expect(await db.select().from(schema.messageAttachments)).toHaveLength(1)

    const result = await addSpaceUrlPreviewExclusion(
      {
        spaceId: BigInt(space.id),
        host: "private.example.com",
        peerId: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } },
        messageId: BigInt(message.messageId),
      },
      testUtils.functionContext({ userId: user.id, sessionId: 1 }),
    )

    if (!result.exclusion) {
      throw new Error("Expected add exclusion result")
    }
    expect(result.exclusion.host).toBe("private.example.com")
    expect(result.exclusion.createdBy).toBe(BigInt(user.id))
    expect(result.updates).toHaveLength(1)
    expect(await db.select().from(schema.messageAttachments)).toHaveLength(0)
  })

  it("does not store authenticated Notion previews in the global cache", async () => {
    const { space, users } = await testUtils.createSpaceWithMembers("Notion URL Preview", ["notion-preview@example.com"])
    const user = users[0]
    if (!space || !user) {
      throw new Error("Failed to create Notion preview test fixtures")
    }

    const chat = await testUtils.createChat(space.id, "Preview Thread", "thread", true, user.id)
    if (!chat) {
      throw new Error("Failed to create Notion preview test chat")
    }

    const message = await testUtils.createTestMessage({
      chatId: chat.id,
      fromId: user.id,
      messageId: 1,
      text: "https://www.notion.so/workspace/Roadmap-0123456789abcdef0123456789abcdef",
    })

    const token = encrypt(JSON.stringify({ data: { access_token: "notion-token" } }))
    await db.insert(schema.integrations).values({
      provider: "notion",
      spaceId: space.id,
      userId: user.id,
      accessTokenEncrypted: token.encrypted,
      accessTokenIv: token.iv,
      accessTokenTag: token.authTag,
    })

    const [previewRoute] = getPreviewRoutesFromMessage(
      "https://www.notion.so/workspace/Roadmap-0123456789abcdef0123456789abcdef",
    )
    if (!previewRoute || previewRoute.kind !== "authenticated") {
      throw new Error("Expected authenticated Notion preview route")
    }

    const fetchedUrls: string[] = []
    globalThis.fetch = (async (url: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
      fetchedUrls.push(String(url))
      expect(new Headers(init?.headers).get("Authorization")).toBe("Bearer notion-token")
      expect(new Headers(init?.headers).get("Notion-Version")).toBe("2026-03-11")
      return Response.json({
        object: "page",
        properties: {
          Name: {
            type: "title",
            title: [{ plain_text: "Product roadmap" }],
          },
          Summary: {
            type: "rich_text",
            rich_text: [{ plain_text: "Launch plan and milestones." }],
          },
        },
      })
    }) as unknown as typeof fetch

    try {
      await processUrlPreview({
        message,
        previewRoute,
        chatId: chat.id,
        currentUserId: user.id,
        inputPeer: { type: { oneofKind: "chat", chat: { chatId: BigInt(chat.id) } } },
      })
    } finally {
      globalThis.fetch = originalFetch
    }

    expect(fetchedUrls).toEqual(["https://api.notion.com/v1/pages/01234567-89ab-cdef-0123-456789abcdef"])

    const cacheRows = await db.select().from(schema.urlPreviewCache)
    expect(cacheRows).toHaveLength(0)

    const [preview] = await db.select().from(schema.urlPreview).limit(1)
    if (!preview) {
      throw new Error("Expected authenticated preview row")
    }
    expect(preview.provider).toBe("notion")
    expect(preview.cacheId).toBeNull()

    const attachments = await db.select().from(schema.messageAttachments)
    expect(attachments).toHaveLength(1)
    expect(attachments[0]?.urlPreviewId).toBe(BigInt(preview.id))
  })
})
