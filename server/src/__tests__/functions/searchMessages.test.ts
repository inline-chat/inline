import { describe, expect, test } from "bun:test"
import { searchMessages } from "../../functions/messages.searchMessages"
import { testUtils, setupTestLifecycle } from "../setup"
import { db } from "../../db"
import * as schema from "../../db/schema"
import { encrypt } from "../../modules/encryption/encryption"
import { SearchMessagesFilter } from "@inline-chat/protocol/core"

const makeFunctionContext = (userId: number): any => ({
  currentUserId: userId,
  currentSessionId: 1,
})

describe("searchMessages", () => {
  setupTestLifecycle()

  test("returns most-recent messages matching all keywords", async () => {
    const userA = (await testUtils.createUser("search-a@example.com"))!
    const userB = (await testUtils.createUser("search-b@example.com"))!
    const chat = (await testUtils.createPrivateChat(userA, userB))!

    await testUtils.createTestMessage({
      messageId: 1,
      chatId: chat.id,
      fromId: userA.id,
      text: "alpha beta",
    })
    await testUtils.createTestMessage({
      messageId: 2,
      chatId: chat.id,
      fromId: userA.id,
      text: "alpha only",
    })
    await testUtils.createTestMessage({
      messageId: 3,
      chatId: chat.id,
      fromId: userA.id,
      text: "beta Alpha",
    })

    const result = await searchMessages(
      {
        peerId: {
          type: { oneofKind: "user", user: { userId: BigInt(userB.id) } },
        },
        queries: ["ALPHA beta"],
      },
      makeFunctionContext(userA.id),
    )

    const ids = result.messages.map((message) => Number(message.id))
    const texts = result.messages.map((message) => message.message)

    expect(ids).toEqual([3, 1])
    expect(texts).toEqual(["beta Alpha", "alpha beta"])
  })

  test("matches any query group", async () => {
    const userA = (await testUtils.createUser("search-or-a@example.com"))!
    const userB = (await testUtils.createUser("search-or-b@example.com"))!
    const chat = (await testUtils.createPrivateChat(userA, userB))!

    await testUtils.createTestMessage({
      messageId: 1,
      chatId: chat.id,
      fromId: userA.id,
      text: "alpha beta",
    })
    await testUtils.createTestMessage({
      messageId: 2,
      chatId: chat.id,
      fromId: userA.id,
      text: "gamma delta",
    })
    await testUtils.createTestMessage({
      messageId: 3,
      chatId: chat.id,
      fromId: userA.id,
      text: "epsilon zeta",
    })

    const result = await searchMessages(
      {
        peerId: {
          type: { oneofKind: "user", user: { userId: BigInt(userB.id) } },
        },
        queries: ["alpha beta", "delta"],
      },
      makeFunctionContext(userA.id),
    )

    expect(result.messages.map((message) => Number(message.id))).toEqual([2, 1])
  })

  test("rejects empty queries", async () => {
    const userA = (await testUtils.createUser("search-c@example.com"))!
    const userB = (await testUtils.createUser("search-d@example.com"))!
    await testUtils.createPrivateChat(userA, userB)

    await expect(
      searchMessages(
        {
          peerId: {
            type: { oneofKind: "user", user: { userId: BigInt(userB.id) } },
          },
          queries: ["   "],
        },
        makeFunctionContext(userA.id),
      ),
    ).rejects.toThrow()
  })

  test("allows empty queries with document filter", async () => {
    const userA = (await testUtils.createUser("search-doc-filter-a@example.com"))!
    const userB = (await testUtils.createUser("search-doc-filter-b@example.com"))!
    const chat = (await testUtils.createPrivateChat(userA, userB))!

    const [file] = await db
      .insert(schema.files)
      .values({
        fileUniqueId: "file-search-doc-filter-1",
        userId: userA.id,
        mimeType: "application/pdf",
        fileSize: 10,
      })
      .returning()

    const [document] = await db
      .insert(schema.documents)
      .values({
        fileId: file!.id,
      })
      .returning()

    await db
      .insert(schema.messages)
      .values({
        messageId: 1,
        chatId: chat.id,
        fromId: userA.id,
        mediaType: "document",
        documentId: document!.id,
      })
      .execute()

    const result = await searchMessages(
      {
        peerId: {
          type: { oneofKind: "user", user: { userId: BigInt(userB.id) } },
        },
        queries: [],
        filter: SearchMessagesFilter.FILTER_DOCUMENTS,
      },
      makeFunctionContext(userA.id),
    )

    expect(result.messages.map((message) => Number(message.id))).toEqual([1])
  })

  test("allows empty queries with links filter", async () => {
    const userA = (await testUtils.createUser("search-links-filter-a@example.com"))!
    const userB = (await testUtils.createUser("search-links-filter-b@example.com"))!
    const chat = (await testUtils.createPrivateChat(userA, userB))!

    await db
      .insert(schema.messages)
      .values({
        messageId: 1,
        chatId: chat.id,
        fromId: userA.id,
        text: "no links here",
        hasLink: false,
      })
      .execute()

    await db
      .insert(schema.messages)
      .values({
        messageId: 2,
        chatId: chat.id,
        fromId: userA.id,
        text: "https://inline.chat",
        hasLink: true,
      })
      .execute()

    const result = await searchMessages(
      {
        peerId: {
          type: { oneofKind: "user", user: { userId: BigInt(userB.id) } },
        },
        queries: [],
        filter: SearchMessagesFilter.FILTER_LINKS,
      },
      makeFunctionContext(userA.id),
    )

    expect(result.messages.map((message) => Number(message.id))).toEqual([2])
  })

  test("applies media filters when searching text", async () => {
    const userA = (await testUtils.createUser("search-media-filter-a@example.com"))!
    const userB = (await testUtils.createUser("search-media-filter-b@example.com"))!
    const chat = (await testUtils.createPrivateChat(userA, userB))!

    await testUtils.createTestMessage({
      messageId: 1,
      chatId: chat.id,
      fromId: userA.id,
      text: "alpha",
    })

    const [photo] = await db
      .insert(schema.photos)
      .values({
        format: "jpeg",
      })
      .returning()

    const encrypted = encrypt("alpha")

    await db
      .insert(schema.messages)
      .values({
        messageId: 2,
        chatId: chat.id,
        fromId: userA.id,
        mediaType: "photo",
        photoId: photo!.id,
        textEncrypted: encrypted.encrypted,
        textIv: encrypted.iv,
        textTag: encrypted.authTag,
      })
      .execute()

    const result = await searchMessages(
      {
        peerId: {
          type: { oneofKind: "user", user: { userId: BigInt(userB.id) } },
        },
        queries: ["alpha"],
        filter: SearchMessagesFilter.FILTER_PHOTOS,
      },
      makeFunctionContext(userA.id),
    )

    expect(result.messages.map((message) => Number(message.id))).toEqual([2])
  })

  test("respects offset_id with media filters", async () => {
    const userA = (await testUtils.createUser("search-offset-a@example.com"))!
    const userB = (await testUtils.createUser("search-offset-b@example.com"))!
    const chat = (await testUtils.createPrivateChat(userA, userB))!

    const [photo] = await db
      .insert(schema.photos)
      .values({
        format: "jpeg",
      })
      .returning()

    await db
      .insert(schema.messages)
      .values({
        messageId: 1,
        chatId: chat.id,
        fromId: userA.id,
        mediaType: "photo",
        photoId: photo!.id,
      })
      .execute()

    const [videoFile] = await db
      .insert(schema.files)
      .values({
        fileUniqueId: "file-search-video-1",
        userId: userA.id,
        mimeType: "video/mp4",
        fileSize: 120,
      })
      .returning()

    const [video] = await db
      .insert(schema.videos)
      .values({
        fileId: videoFile!.id,
      })
      .returning()

    await db
      .insert(schema.messages)
      .values({
        messageId: 2,
        chatId: chat.id,
        fromId: userA.id,
        mediaType: "video",
        videoId: video!.id,
      })
      .execute()

    const result = await searchMessages(
      {
        peerId: {
          type: { oneofKind: "user", user: { userId: BigInt(userB.id) } },
        },
        queries: [],
        filter: SearchMessagesFilter.FILTER_PHOTO_VIDEO,
        offsetId: 2n,
      },
      makeFunctionContext(userA.id),
    )

    expect(result.messages.map((message) => Number(message.id))).toEqual([1])
  })

  test("matches keywords in attached document file name", async () => {
    const userA = (await testUtils.createUser("search-file-a@example.com"))!
    const userB = (await testUtils.createUser("search-file-b@example.com"))!
    const chat = (await testUtils.createPrivateChat(userA, userB))!

    const [file] = await db
      .insert(schema.files)
      .values({
        fileUniqueId: "file-search-doc-1",
        userId: userA.id,
        mimeType: "application/pdf",
        fileSize: 123,
      })
      .returning()

    const encryptedFileName = encrypt("Quarterly_Report_2025.pdf")

    const [document] = await db
      .insert(schema.documents)
      .values({
        fileId: file!.id,
        fileName: encryptedFileName.encrypted,
        fileNameIv: encryptedFileName.iv,
        fileNameTag: encryptedFileName.authTag,
      })
      .returning()

    await db
      .insert(schema.messages)
      .values({
        messageId: 1,
        chatId: chat.id,
        fromId: userA.id,
        mediaType: "document",
        documentId: document!.id,
      })
      .execute()

    const result = await searchMessages(
      {
        peerId: {
          type: { oneofKind: "user", user: { userId: BigInt(userB.id) } },
        },
        queries: ["report 2025"],
      },
      makeFunctionContext(userA.id),
    )

    expect(result.messages.length).toBe(1)

    const media = result.messages[0]?.media?.media
    expect(media?.oneofKind).toBe("document")
    if (media?.oneofKind === "document") {
      expect(media.document.document!.fileName).toBe("Quarterly_Report_2025.pdf")
    }
  })

  test("handles large datasets without excessive time or memory", async () => {
    const userA = (await testUtils.createUser("search-big-a@example.com"))!
    const userB = (await testUtils.createUser("search-big-b@example.com"))!
    const chat = (await testUtils.createPrivateChat(userA, userB))!

    const totalMessages = 12000
    const matchEvery = 100
    const limit = 25
    const batchSize = 1000

    const matchEncrypted = encrypt("alpha beta gamma")
    const otherEncrypted = encrypt("lorem ipsum dolor sit amet")

    for (let start = 1; start <= totalMessages; start += batchSize) {
      const rows: Array<{
        messageId: number
        chatId: number
        fromId: number
        textEncrypted: Buffer
        textIv: Buffer
        textTag: Buffer
      }> = []

      const end = Math.min(totalMessages, start + batchSize - 1)
      for (let messageId = start; messageId <= end; messageId += 1) {
        const encrypted = messageId % matchEvery === 0 ? matchEncrypted : otherEncrypted
        rows.push({
          messageId,
          chatId: chat.id,
          fromId: userA.id,
          textEncrypted: encrypted.encrypted,
          textIv: encrypted.iv,
          textTag: encrypted.authTag,
        })
      }

      await db.insert(schema.messages).values(rows).execute()
      rows.length = 0
    }

    const expectedIds: number[] = []
    for (let messageId = totalMessages; messageId >= 1 && expectedIds.length < limit; messageId -= 1) {
      if (messageId % matchEvery === 0) {
        expectedIds.push(messageId)
      }
    }

    const memoryBefore = process.memoryUsage().heapUsed
    const startTime = performance.now()

    const result = await searchMessages(
      {
        peerId: {
          type: { oneofKind: "user", user: { userId: BigInt(userB.id) } },
        },
        queries: ["alpha beta"],
        limit,
      },
      makeFunctionContext(userA.id),
    )

    const durationMs = performance.now() - startTime
    const memoryAfter = process.memoryUsage().heapUsed
    const memoryDelta = Math.max(0, memoryAfter - memoryBefore)

    expect(result.messages.length).toBe(limit)
    expect(result.messages.map((message) => Number(message.id))).toEqual(expectedIds)
    expect(durationMs).toBeLessThan(5000)
    expect(memoryDelta).toBeLessThan(250 * 1024 * 1024)
  })
})
