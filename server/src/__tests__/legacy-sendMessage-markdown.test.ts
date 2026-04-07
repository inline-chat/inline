import { describe, expect, it } from "bun:test"
import { app } from "../index"
import { db } from "@in/server/db"
import { messages, users } from "@in/server/db/schema"
import { and, eq } from "drizzle-orm"
import { setupTestLifecycle, testUtils } from "./setup"

describe("legacy /v1/sendMessage markdown", () => {
  setupTestLifecycle()

  it("parses markdown by default and stores entities", async () => {
    const [user] = await db
      .insert(users)
      .values({
        firstName: "LegacyMd",
        username: "legacymd",
        bot: false,
        emailVerified: false,
        phoneVerified: false,
        pendingSetup: false,
      })
      .returning()
    expect(user).toBeDefined()

    const chat = await testUtils.createPrivateChat(user!, user!)
    expect(chat).toBeDefined()

    const { token } = await testUtils.createSessionForUser(user!.id, { clientType: "api" })
    const rawText = "hello **world** [link](https://example.com)"

    const res = await app.handle(
      new Request("http://localhost/v1/sendMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          peerThreadId: chat!.id,
          text: rawText,
        }),
      }),
    )

    expect(res.status).toBe(200)
    const json = await res.json()
    expect(json.ok).toBe(true)
    expect(json.result.message.text).toBe("hello world link")

    const [row] = await db
      .select()
      .from(messages)
      .where(and(eq(messages.chatId, chat!.id), eq(messages.messageId, 1)))
      .limit(1)
    expect(row).toBeDefined()
    expect(row?.entitiesEncrypted).toBeTruthy()
    expect(row?.entitiesIv).toBeTruthy()
    expect(row?.entitiesTag).toBeTruthy()
  })

  it("preserves raw text when parseMarkdown is false", async () => {
    const [user] = await db
      .insert(users)
      .values({
        firstName: "LegacyRaw",
        username: "legacyraw",
        bot: false,
        emailVerified: false,
        phoneVerified: false,
        pendingSetup: false,
      })
      .returning()
    expect(user).toBeDefined()

    const chat = await testUtils.createPrivateChat(user!, user!)
    expect(chat).toBeDefined()

    const { token } = await testUtils.createSessionForUser(user!.id, { clientType: "api" })
    const rawText = "hello **world** [link](https://example.com)"

    const res = await app.handle(
      new Request("http://localhost/v1/sendMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          peerThreadId: chat!.id,
          text: rawText,
          parseMarkdown: false,
        }),
      }),
    )

    expect(res.status).toBe(200)
    const json = await res.json()
    expect(json.ok).toBe(true)
    expect(json.result.message.text).toBe(rawText)

    const [row] = await db
      .select()
      .from(messages)
      .where(and(eq(messages.chatId, chat!.id), eq(messages.messageId, 1)))
      .limit(1)
    expect(row).toBeDefined()
    expect(row?.entitiesEncrypted).toBeNull()
    expect(row?.entitiesIv).toBeNull()
    expect(row?.entitiesTag).toBeNull()
  })
})
