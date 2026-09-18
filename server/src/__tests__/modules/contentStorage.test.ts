import { afterEach, beforeEach, describe, expect, it } from "bun:test"
import { and, eq, sql } from "drizzle-orm"
import { db } from "@in/server/db"
import { chats, dialogs, reactions, voices, urlPreview, urlPreviewCache, externalTasks, inlineUploads, inlineProtocolUploads, inlineProtocolAuthKeys, blockContents, blockContentImageJobs } from "@in/server/db/schema"
import { ReactionModel } from "@in/server/db/models/reactions"
import { chatTitleFields, chatTitleMatches } from "@in/server/modules/encryption/chatTitleStorage"
import { CONTENT_PREFIX, contentLookup, openContentText } from "@in/server/modules/encryption/contentEncryption"
import { InlineUploadRepository } from "@in/server/db/models/inlineUploads"
import { backfillContentBatch, contentTables, remainingPlaintext } from "../../../scripts/helpers/content-backfill"
import { setupTestLifecycle, testUtils } from "../setup"

import { encrypt } from "@in/server/modules/encryption/encryption"
import { createHash } from "node:crypto"
import { getFreshPreviewCache, upsertPreviewCache } from "@in/server/modules/urlPreview/cache"

const originalMode = process.env["CONTENT_ENCRYPTION_WRITES"]
const table = (name: string) => contentTables.find((table) => table.name === name)!

// SQL below deliberately bypasses codecs so assertions examine actual persisted values.
describe("encrypted content storage compatibility", () => {
  setupTestLifecycle()
  beforeEach(() => { process.env["CONTENT_ENCRYPTION_WRITES"] = "true" })
  afterEach(() => {
    if (originalMode === undefined) Reflect.deleteProperty(process.env, "CONTENT_ENCRYPTION_WRITES")
    else process.env["CONTENT_ENCRYPTION_WRITES"] = originalMode
  })

  it("preserves insert, projection, relational read and clearing semantics", async () => {
    const user = await testUtils.createUser()
    const [chat] = await db.insert(chats).values({ type: "thread", createdBy: user.id,
      ...chatTitleFields("Private title", { spaceId: null, createdBy: user.id }),
      description: "Private description", emoji: "🪴" }).returning()
    expect(chat!.title).toBe("Private title")
    await db.insert(dialogs).values({ chatId: chat!.id, userId: user.id, draft: "Private draft" })
    const relational = await db._query.chats.findFirst({ where: eq(chats.id, chat!.id), with: { dialogs: true } })
    expect(relational!.description).toBe("Private description")
    expect(relational!.dialogs[0]!.draft).toBe("Private draft")
    expect((await db.select({ title: chats.title }).from(chats))[0]!.title).toBe("Private title")
    const [raw] = await db.execute<{ title: string; description: string; emoji: string }>(sql`select title, description, emoji from chats`)
    for (const value of Object.values(raw!)) expect(value.startsWith(CONTENT_PREFIX)).toBe(true)
    expect(JSON.stringify(raw)).not.toContain("Private")
    await db.update(dialogs).set({ draft: "" })
    expect((await db.select().from(dialogs))[0]!.draft).toBe("")
    await db.update(dialogs).set({ draft: null })
    expect((await db.select().from(dialogs))[0]!.draft).toBeNull()
    await expect((async () => { await db.update(chats).set({ title: "a".repeat(151) }) })()).rejects.toThrow()
  })

  it("finds legacy and encrypted titles with scoped case-insensitive indexes", async () => {
    const first = (await testUtils.createSpace())!
    const second = (await testUtils.createSpace("Second"))!
    for (const title of [" Launch ", "Café", "سلام", "🪴"]) {
      process.env["CONTENT_ENCRYPTION_WRITES"] = "false"
      await db.insert(chats).values({ type: "thread", spaceId: first.id, title })
      process.env["CONTENT_ENCRYPTION_WRITES"] = "true"
      await db.insert(chats).values({ type: "thread", spaceId: second.id, ...chatTitleFields(title, { spaceId: second.id }) })
      for (const spaceId of [first.id, second.id]) {
        const found = await db.select().from(chats).where(and(eq(chats.spaceId, spaceId), chatTitleMatches(title, { spaceId })))
        expect(found).toHaveLength(1)
        expect(found[0]!.title).toBe(title)
      }
    }
    expect((await db.select().from(chats).where(chatTitleMatches("launch", { spaceId: 999999 })))).toHaveLength(0)
  })

  it("keeps reaction uniqueness under concurrent retries and legacy migration", async () => {
    const user = await testUtils.createUser()
    const chat = (await testUtils.createChat(null))!
    await testUtils.createTestMessage({ chatId: chat.id, fromId: user.id, messageId: 1, text: "message" })
    const input = { chatId: chat.id, messageId: 1, userId: user.id, emoji: "🪴" }
    const results = await Promise.all(Array.from({ length: 8 }, () => ReactionModel.insertReaction(input)))
    expect(results.filter(Boolean)).toHaveLength(1)
    expect((await ReactionModel.getReactions(1n, BigInt(chat.id)))[0]!.emoji).toBe("🪴")
    expect((await db.execute<{ emoji: string }>(sql`select emoji from reactions`))[0]!.emoji.startsWith(CONTENT_PREFIX)).toBe(true)
    expect(await ReactionModel.deleteReaction(1n, chat.id, "🪴", user.id)).toHaveLength(1)
    process.env["CONTENT_ENCRYPTION_WRITES"] = "false"
    await db.insert(reactions).values(input)
    process.env["CONTENT_ENCRYPTION_WRITES"] = "true"
    await Promise.all(Array.from({ length: 4 }, () => ReactionModel.insertReaction(input)))
    expect(await db.select().from(reactions)).toHaveLength(1)
    expect((await backfillContentBatch({ table: table("reactions"), apply: true })).changed).toBe(1)
    expect(await ReactionModel.deleteReaction(1n, chat.id, "🪴", user.id)).toHaveLength(1)
  })

  it("encrypts preview names, task URLs and voice waveforms while preserving reads", async () => {
    await db.insert(urlPreview).values({ siteName: "private site" })
    await db.insert(urlPreviewCache).values({ siteName: "private site", urlHash: Buffer.alloc(32),
      url: Buffer.alloc(1), urlIv: Buffer.alloc(12), urlTag: Buffer.alloc(16),
      fetchedAt: new Date(), lastUsedAt: new Date(), expiresAt: new Date() })
    await db.insert(externalTasks).values({ application: "linear", taskId: "1", status: "todo", url: "https://example.com/private-task" })
    const waveform = Buffer.from([1, 3, 255, 0])
    const [voice] = await db.insert(voices).values({ waveform }).returning()
    expect(voice!.waveform).toEqual(waveform)
    expect((await db._query.voices.findFirst())!.waveform).toEqual(waveform)
    expect((await db.select().from(urlPreview))[0]!.siteName).toBe("private site")
    expect((await db.select().from(externalTasks))[0]!.url).toBe("https://example.com/private-task")
    for (const [name, column] of [["url_preview", "site_name"], ["url_preview_cache", "site_name"], ["external_tasks", "url"]] as const) {
      const [raw] = await db.execute<{ value: string }>(sql`select ${sql.identifier(column)} as value from ${sql.identifier(name)}`)
      expect(raw!.value.startsWith(CONTENT_PREFIX)).toBe(true)
      expect(raw!.value).not.toContain("private")
    }
    expect((await db.execute<{ waveform: Buffer }>(sql`select waveform from voices`))[0]!.waveform).not.toEqual(waveform)
  })

  it("keeps upload retries idempotent with encrypted filename and waveform", async () => {
    const user = await testUtils.createUser()
    const account = await testUtils.createSessionForUser(user.id)
    const owner = { userId: user.id, accountSessionId: account.session.id }
    const repository = new InlineUploadRepository()
    const metadata = { clientUploadId: new Uint8Array(16).fill(1), fileName: "private-voice.ogg", mimeType: "audio/ogg",
      byteCount: 1n, sha256: Buffer.alloc(32), kind: "voice" as const, waveform: Buffer.from([1, 2]), duration: 1 }
    const created = await repository.create(owner, metadata)
    expect((await repository.create(owner, metadata)).upload.id).toBe(created.upload.id)
    await expect(repository.create(owner, { ...metadata, fileName: "other.ogg" })).rejects.toThrow()
    expect((await repository.get(created.upload.uploadId, owner))!.fileName).toBe(metadata.fileName)
    expect((await db.select().from(inlineUploads))[0]!.waveform).toEqual(metadata.waveform)
    const [raw] = await db.execute<{ file_name: string }>(sql`select file_name from inline_uploads`)
    expect(raw!.file_name.startsWith(CONTENT_PREFIX)).toBe(true)
  })

  it("verifies before replacing legacy content, resumes bounded batches and remains idempotent", async () => {
    process.env["CONTENT_ENCRYPTION_WRITES"] = "false"
    for (const title of ["", "legacy one", "legacy two"]) await testUtils.createChat(null, title)
    const dry = await backfillContentBatch({ table: table("chats"), apply: false, batchSize: 2 })
    expect(dry).toMatchObject({ scanned: 2, changed: 2, done: false })
    expect((await remainingPlaintext())["chats"]).toBe(3)
    process.env["CONTENT_ENCRYPTION_WRITES"] = "true"
    const first = await backfillContentBatch({ table: table("chats"), apply: true, batchSize: 2 })
    expect((await backfillContentBatch({ table: table("chats"), apply: true, afterId: first.lastId, batchSize: 2 })).changed).toBe(1)
    expect((await remainingPlaintext())["chats"]).toBe(0)
    expect((await backfillContentBatch({ table: table("chats"), apply: true })).changed).toBe(0)
    expect((await db.select().from(chats)).map((row) => row.title).sort()).toEqual(["", "legacy one", "legacy two"])
  })

  it("rolls back the batch on tampered ciphertext without rewriting its legacy neighbors", async () => {
    process.env["CONTENT_ENCRYPTION_WRITES"] = "false"
    const first = (await testUtils.createChat(null, "safe legacy"))!
    const second = (await testUtils.createChat(null, "later"))!
    await db.execute(sql`update chats set title = ${CONTENT_PREFIX + "bad!"} where id = ${second.id}`)
    await expect(backfillContentBatch({ table: table("chats"), apply: true })).rejects.toThrow()
    const [raw] = await db.execute<{ title: string }>(sql`select title from chats where id = ${first.id}`)
    expect(raw!.title).toBe("safe legacy")
  })

  it("migrates binary upload cursors, empty waveforms and legacy attachment and draft metadata", async () => {
    process.env["CONTENT_ENCRYPTION_WRITES"] = "false"
    const user = await testUtils.createUser()
    const { session } = await testUtils.createSessionForUser(user.id)
    const chat = (await testUtils.createChat(null, "legacy thread"))!
    await db.insert(dialogs).values({ chatId: chat.id, userId: user.id, draft: "" })
    await db.insert(inlineProtocolAuthKeys).values({ authKeyId: Buffer.alloc(8, 1),
      authKeyEncrypted: Buffer.alloc(284), keyEncryptionKeyId: "test", currentServerSalt: 1n })
    for (const id of [1, 255]) {
      await db.insert(inlineProtocolUploads).values({ uploadId: Buffer.alloc(16, id), capabilityHash: Buffer.alloc(32, id),
        permanentAuthKeyId: Buffer.alloc(8, 1), issuingTemporaryAuthKeyId: Buffer.alloc(8, 2),
        userId: user.id, accountSessionId: session.id, fileName: `private-${id}.ogg`, mimeType: "audio/ogg",
        byteCount: 1n, sha256: Buffer.alloc(32), kind: "voice", expiresAt: new Date(Date.now() + 60_000) })
    }
    await new InlineUploadRepository().create({ userId: user.id, accountSessionId: session.id }, {
      clientUploadId: new Uint8Array(16).fill(3), fileName: "private-staged.ogg", mimeType: "audio/ogg",
      byteCount: 1n, sha256: Buffer.alloc(32), kind: "voice", waveform: Buffer.from([0, 255]), duration: 1,
    })
    await db.insert(voices).values([{ waveform: Buffer.alloc(0) }, { waveform: null }])
    await db.insert(urlPreview).values({ siteName: "private legacy site" })
    await db.insert(externalTasks).values({ application: "linear", taskId: "1", status: "todo", url: "https://example.com/private" })
    process.env["CONTENT_ENCRYPTION_WRITES"] = "true"
    for (const name of ["chats", "dialogs", "inline_protocol_uploads", "inline_uploads", "voices", "url_preview", "external_tasks"]) {
      let afterId: string | undefined
      let scanned = 0
      while (true) {
        const batch = await backfillContentBatch({ table: table(name), apply: true, batchSize: 1, afterId })
        scanned += batch.scanned
        if (batch.done) break
        expect(batch.lastId).not.toBe(afterId)
        afterId = batch.lastId
      }
      expect(scanned).toBe(name === "inline_protocol_uploads" || name === "voices" ? 2 : 1)
    }
    expect(Object.values(await remainingPlaintext()).every((count) => count === 0)).toBe(true)
    expect((await db.select().from(dialogs))[0]!.draft).toBe("")
    expect((await db.select().from(inlineProtocolUploads)).map((row) => row.fileName).sort()).toEqual(["private-1.ogg", "private-255.ogg"])
    expect((await db.select().from(inlineUploads))[0]).toMatchObject({ fileName: "private-staged.ogg", waveform: Buffer.from([0, 255]) })
    const migratedVoices = await db.select().from(voices)
    expect(migratedVoices.some((row) => row.waveform?.byteLength === 0)).toBe(true)
    expect(migratedVoices.some((row) => row.waveform === null)).toBe(true)
    expect((await db.select().from(urlPreview))[0]!.siteName).toBe("private legacy site")
    expect((await db.select().from(externalTasks))[0]!.url).toBe("https://example.com/private")
  })

  it("upgrades URL fingerprints without losing preview identities or image jobs", async () => {
    process.env["CONTENT_ENCRYPTION_WRITES"] = "false"
    const url = "https://example.com/private-url"
    const metadata = { url, finalUrl: url, provider: "generic" as const, title: "private title", siteName: "private site", imageUrl: url }
    const legacy = await upsertPreviewCache({ metadata, photoId: null })
    const [content] = await db.insert(blockContents).values({ payloadEncrypted: Buffer.alloc(1), payloadIv: Buffer.alloc(12), payloadTag: Buffer.alloc(16) }).returning()
    const source = encrypt(url)
    await db.insert(blockContentImageJobs).values({ contentId: content!.id, expectedRevision: 0, blockPath: [0],
      sourceHash: createHash("sha256").update(url).digest(), sourceEncrypted: source.encrypted,
      sourceIv: source.iv, sourceTag: source.authTag, state: "processing", leaseToken: "synthetic-lease" })
    process.env["CONTENT_ENCRYPTION_WRITES"] = "true"
    expect((await getFreshPreviewCache(url))!.id).toBe(legacy.id)
    expect((await upsertPreviewCache({ metadata, photoId: null })).id).toBe(legacy.id)
    expect(await db.select().from(urlPreviewCache)).toHaveLength(1)
    await backfillContentBatch({ table: table("url_preview_cache"), apply: true })
    await backfillContentBatch({ table: table("block_content_image_jobs"), apply: true })
    const [cache] = await db.select().from(urlPreviewCache)
    expect(cache!.urlHash).toEqual(contentLookup("preview-url", [], url))
    expect(cache!.imageUrlHash).toEqual(contentLookup("preview-url", [], url))
    const [job] = await db.select().from(blockContentImageJobs)
    expect(job!.sourceHash).toEqual(contentLookup("block-image-url", [], url))
    expect(job).toMatchObject({ state: "processing", leaseToken: "synthetic-lease", expectedRevision: 0, hashVersion: 1 })
    expect((await backfillContentBatch({ table: table("block_content_image_jobs"), apply: true })).changed).toBe(0)
  })

  it("applies one Unicode normalization consistently after migration", async () => {
    const space = (await testUtils.createSpace())!
    process.env["CONTENT_ENCRYPTION_WRITES"] = "false"
    await testUtils.createChat(space.id, "İstanbul")
    process.env["CONTENT_ENCRYPTION_WRITES"] = "true"
    await backfillContentBatch({ table: table("chats"), apply: true })
    const found = await db.select().from(chats).where(chatTitleMatches("İSTANBUL", { spaceId: space.id }))
    expect(found).toHaveLength(1)
    expect(found[0]!.title).toBe("İstanbul")
  })

  it("preserves one preview identity as upgraded writers enable encryption at different times", async () => {
    const metadata = { url: "https://example.com/rolling-preview", finalUrl: "https://example.com/rolling-preview", provider: "generic" as const,
      siteName: "private preview", imageUrl: "https://example.com/private-image" }
    const createdAt = new Date("2026-01-01T00:00:00Z")
    const first = await upsertPreviewCache({ metadata, photoId: null, now: createdAt })
    process.env["CONTENT_ENCRYPTION_WRITES"] = "false"
    const second = await upsertPreviewCache({ metadata, photoId: null })
    expect(second.id).toBe(first.id)
    expect(second.hashVersion).toBe(1)
    expect(second.createdAt).toEqual(createdAt)
    process.env["CONTENT_ENCRYPTION_WRITES"] = "true"
    const concurrent = await Promise.all(Array.from({ length: 8 }, () => upsertPreviewCache({ metadata, photoId: null })))
    expect(concurrent.every((row) => row.id === first.id)).toBe(true)
    expect(await db.select().from(urlPreviewCache)).toHaveLength(1)
    await backfillContentBatch({ table: table("url_preview_cache"), apply: true })
    expect((await getFreshPreviewCache(metadata.url))!.id).toBe(first.id)
  })

  it("does not lose an edit racing the migration", async () => {
    process.env["CONTENT_ENCRYPTION_WRITES"] = "false"
    const chat = (await testUtils.createChat(null, "old"))!
    process.env["CONTENT_ENCRYPTION_WRITES"] = "true"
    let locked!: () => void
    let release!: () => void
    const acquired = new Promise<void>((resolve) => { locked = resolve })
    const unblock = new Promise<void>((resolve) => { release = resolve })
    const edit = db.transaction(async (tx) => {
      await tx.select().from(chats).where(eq(chats.id, chat.id)).for("update")
      locked()
      await unblock
      await tx.update(chats).set(chatTitleFields("latest", { spaceId: null })).where(eq(chats.id, chat.id))
    })
    await acquired
    const backfill = backfillContentBatch({ table: table("chats"), apply: true })
    release()
    await edit
    await backfill
    const [raw] = await db.execute<{ title: string }>(sql`select title from chats where id = ${chat.id}`)
    expect(openContentText(raw!.title, "chats.title")).toBe("latest")
  })
})
