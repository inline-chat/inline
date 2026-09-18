import { afterEach, describe, expect, it } from "bun:test"
import { sql } from "drizzle-orm"
import { db } from "@in/server/db"
import { chats, messages, voices } from "@in/server/db/schema"
import { encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { chatTitleFields } from "@in/server/modules/encryption/chatTitleStorage"
import { handler as addReaction } from "@in/server/methods/addReaction"
import { handler as createPrivateChat } from "@in/server/methods/createPrivateChat"
import { constrainEncryptedContent, remainingPlaintext } from "../../../scripts/helpers/content-backfill"
import { setupTestLifecycle, testUtils } from "../setup"

const originalMode = process.env["CONTENT_ENCRYPTION_WRITES"]
describe("content backfill completion constraints", () => {
  setupTestLifecycle()
  afterEach(() => {
    if (originalMode === undefined) Reflect.deleteProperty(process.env, "CONTENT_ENCRYPTION_WRITES")
    else process.env["CONTENT_ENCRYPTION_WRITES"] = originalMode
  })
  it("validates idempotently, accepts encrypted writes and rejects plaintext regression", async () => {
    process.env["CONTENT_ENCRYPTION_WRITES"] = "true"
    await db.insert(chats).values({ type: "thread", ...chatTitleFields("private", { spaceId: null }) })
    await db.insert(voices).values({ waveform: Buffer.from([1, 2]) })
    expect(Object.values(await remainingPlaintext()).every((value) => value === 0)).toBe(true)
    await constrainEncryptedContent()
    await constrainEncryptedContent()
    await db.insert(chats).values({ type: "thread", ...chatTitleFields("another", { spaceId: null }) })
    await expect((async () => { await db.execute(sql`update chats set title = 'plaintext regression'`) })()).rejects.toThrow()
    await expect((async () => { await db.execute(sql`update voices set waveform = decode('0102', 'hex')`) })()).rejects.toThrow()
    const constraints = await db.execute<{ conname: string; convalidated: boolean }>(sql`
      select conname, convalidated from pg_constraint
      where conname like '%content_encrypted_v1' or conname in ('messages_no_plaintext_v1', 'replay_no_plaintext_v1')
    `)
    expect(constraints).toHaveLength(12)
    expect(constraints.every((constraint) => constraint.convalidated)).toBe(true)

    const user = await testUtils.createUser()
    const chat = (await testUtils.createPrivateChat(user, user))!
    const ciphertext = encryptMessage("private message")
    await db.insert(messages).values({ chatId: chat.id, messageId: 1, fromId: user.id,
      textEncrypted: ciphertext.encrypted, textIv: ciphertext.iv, textTag: ciphertext.authTag })
    const input = { chatId: chat.id, messageId: 1, emoji: "🪴" }
    const context = { currentUserId: user.id, currentSessionId: 0, ip: "127.0.0.1" }
    expect((await addReaction(input, context)).reaction.emoji).toBe("🪴")
    await expect(addReaction(input, context)).rejects.toMatchObject({ type: "INTERNAL" })
    const stored = await db.execute<{ emoji: string; emoji_hash: Buffer }>(sql`select emoji, emoji_hash from reactions`)
    expect(stored).toHaveLength(1)
    expect(stored[0]!.emoji).not.toContain("🪴")
    expect(stored[0]!.emoji_hash.byteLength).toBe(32)

    // The legacy self-chat path also writes a title, including on the conflict/update path.
    const selfChat = await createPrivateChat({ userId: String(user.id) }, context)
    expect(Number(selfChat.chat.id)).toBe(chat.id)
    expect(Number((await createPrivateChat({ userId: String(user.id) }, context)).chat.id)).toBe(chat.id)
    const [rawSelf] = await db.execute<{ title_hash: Buffer }>(sql`select title_hash from chats where id = ${chat.id}`)
    expect(rawSelf!.title_hash.byteLength).toBe(32)
  })
})
