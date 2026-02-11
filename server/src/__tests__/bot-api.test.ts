import { describe, expect, it } from "bun:test"
import { app } from "../index"
import { db } from "@in/server/db"
import { users } from "@in/server/db/schema/users"
import { generateToken, hashToken } from "@in/server/utils/auth"
import { SessionsModel } from "@in/server/db/models/sessions"
import { setupTestLifecycle } from "./setup"

describe("Bot HTTP API", () => {
  setupTestLifecycle()

  it("supports Authorization header auth at /bot/<method>", async () => {
    const [bot] = await db
      .insert(users)
      .values({
        firstName: "TestBot",
        username: "testbot",
        bot: true,
        emailVerified: false,
        phoneVerified: false,
        pendingSetup: false,
      })
      .returning()

    expect(bot).toBeDefined()

    const { token } = await generateToken(bot!.id)
    await SessionsModel.create({
      userId: bot!.id,
      tokenHash: hashToken(token),
      personalData: {},
      clientType: "api",
    })

    const res = await app.handle(
      new Request("http://localhost/bot/getMe", {
        method: "GET",
        headers: {
          Authorization: `Bearer ${token}`,
        },
      }),
    )

    expect(res.status).toBe(200)
    const json = await res.json()
    expect(json).toMatchObject({
      ok: true,
      result: {
        user: {
          id: bot!.id,
          is_bot: true,
          username: "testbot",
          first_name: "TestBot",
        },
      },
    })
  })

  it("supports token-in-path auth at /bot<token>/<method>", async () => {
    const [bot] = await db
      .insert(users)
      .values({
        firstName: "PathBot",
        username: "pathbot",
        bot: true,
        emailVerified: false,
        phoneVerified: false,
        pendingSetup: false,
      })
      .returning()

    const { token } = await generateToken(bot!.id)
    await SessionsModel.create({
      userId: bot!.id,
      tokenHash: hashToken(token),
      personalData: {},
      clientType: "api",
    })

    const res = await app.handle(new Request(`http://localhost/bot${token}/getMe`, { method: "GET" }))
    expect(res.status).toBe(200)
    const json = await res.json()
    expect(json.ok).toBe(true)
    expect(json.result.user.username).toBe("pathbot")
  })

  it("supports URL-encoded token-in-path auth", async () => {
    const [bot] = await db
      .insert(users)
      .values({
        firstName: "EncodedPathBot",
        username: "encodedpathbot",
        bot: true,
        emailVerified: false,
        phoneVerified: false,
        pendingSetup: false,
      })
      .returning()

    const { token } = await generateToken(bot!.id)
    await SessionsModel.create({
      userId: bot!.id,
      tokenHash: hashToken(token),
      personalData: {},
      clientType: "api",
    })

    const encodedToken = encodeURIComponent(token)
    const res = await app.handle(new Request(`http://localhost/bot${encodedToken}/getMe`, { method: "GET" }))
    expect(res.status).toBe(200)
    const json = await res.json()
    expect(json.ok).toBe(true)
    expect(json.result.user.username).toBe("encodedpathbot")
  })

  it("rejects malformed id strings instead of truncating", async () => {
    const [bot] = await db
      .insert(users)
      .values({
        firstName: "StrictIdBot",
        username: "strictidbot",
        bot: true,
        emailVerified: false,
        phoneVerified: false,
        pendingSetup: false,
      })
      .returning()

    const { token } = await generateToken(bot!.id)
    await SessionsModel.create({
      userId: bot!.id,
      tokenHash: hashToken(token),
      personalData: {},
      clientType: "api",
    })

    const res = await app.handle(
      new Request("http://localhost/bot/getChat?user_id=12703abc", {
        method: "GET",
        headers: { Authorization: `Bearer ${token}` },
      }),
    )

    expect(res.status).toBe(400)
    const json = await res.json()
    expect(json.ok).toBe(false)
    expect(json.error_code).toBe(400)
    expect(json.error).toBe("BAD_REQUEST")
  })

  it("supports minimal message actions", async () => {
    const [bot] = await db
      .insert(users)
      .values({
        firstName: "ActionsBot",
        username: "actionsbot",
        bot: true,
        emailVerified: false,
        phoneVerified: false,
        pendingSetup: false,
      })
      .returning()

    const [human] = await db
      .insert(users)
      .values({
        firstName: "Human",
        username: "human",
        bot: false,
        emailVerified: false,
        phoneVerified: false,
        pendingSetup: false,
      })
      .returning()

    const { token } = await generateToken(bot!.id)
    await SessionsModel.create({
      userId: bot!.id,
      tokenHash: hashToken(token),
      personalData: {},
      clientType: "api",
    })

    // Ensure DM chat exists (legacy sendMessage requires it).
    const chatRes = await app.handle(
      new Request(`http://localhost/bot/getChat?user_id=${human!.id}`, {
        method: "GET",
        headers: { Authorization: `Bearer ${token}` },
      }),
    )
    expect(chatRes.status).toBe(200)
    const chatJson = await chatRes.json()
    expect(chatJson.ok).toBe(true)
    const chatId = chatJson.result.chat.chat_id as number

    // Send a message (user_id target)
    const sendRes = await app.handle(
      new Request("http://localhost/bot/sendMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          text: "hello",
          entities: [{ type: "BOLD", offset: "0", length: "5" }],
        }),
      }),
    )
    expect(sendRes.status).toBe(200)
    const sendJson = await sendRes.json()
    expect(sendJson.ok).toBe(true)
    const messageId = sendJson.result.message.message_id as number
    expect(sendJson.result.message.entities).toBeDefined()
    expect(sendJson.result.message.chat.peer).toBeUndefined()
    expect(sendJson.result.message.from.id).toBe(bot!.id)

    // getChat includes last_message with contents for cacheless bot clients.
    const chatAfterSendRes = await app.handle(
      new Request(`http://localhost/bot/getChat?chat_id=${chatId}`, {
        method: "GET",
        headers: { Authorization: `Bearer ${token}` },
      }),
    )
    expect(chatAfterSendRes.status).toBe(200)
    const chatAfterSendJson = await chatAfterSendRes.json()
    expect(chatAfterSendJson.ok).toBe(true)
    expect(chatAfterSendJson.result.chat.last_message_id).toBe(messageId)
    expect(chatAfterSendJson.result.chat.last_message.message_id).toBe(messageId)
    expect(chatAfterSendJson.result.chat.last_message.text).toBe("hello")
    expect(chatAfterSendJson.result.chat.last_message.from.id).toBe(bot!.id)

    // Edit the message (chat_id target; DM chat_id should resolve to the user peer internally)
    const editRes = await app.handle(
      new Request("http://localhost/bot/editMessageText", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          chat_id: chatId,
          message_id: messageId,
          text: "edited",
          entities: [{ type: "ITALIC", offset: "0", length: "6" }],
        }),
      }),
    )
    expect(editRes.status).toBe(200)
    const editJson = await editRes.json()
    expect(editJson.ok).toBe(true)
    expect(editJson.result.message.text).toBe("edited")
    expect(editJson.result.message.entities).toBeDefined()

    // React to the message (chat_id target)
    const reactRes = await app.handle(
      new Request("http://localhost/bot/sendReaction", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ chat_id: chatId, message_id: messageId, emoji: "👍" }),
      }),
    )
    expect(reactRes.status).toBe(200)
    const reactJson = await reactRes.json()
    expect(reactJson.ok).toBe(true)

    // Compatibility convenience: POST accepts query params too.
    const reactQueryRes = await app.handle(
      new Request(
        `http://localhost/bot/sendReaction?chat_id=${chatId}&message_id=${messageId}&emoji=${encodeURIComponent("🔥")}`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${token}`,
          },
        },
      ),
    )
    expect(reactQueryRes.status).toBe(200)
    const reactQueryJson = await reactQueryRes.json()
    expect(reactQueryJson.ok).toBe(true)

    // Fetch chat history
    const histRes = await app.handle(
      new Request(`http://localhost/bot/getChatHistory?chat_id=${chatId}&limit=10`, {
        method: "GET",
        headers: { Authorization: `Bearer ${token}` },
      }),
    )
    expect(histRes.status).toBe(200)
    const histJson = await histRes.json()
    expect(histJson.ok).toBe(true)
    expect(Array.isArray(histJson.result.messages)).toBe(true)
    expect(histJson.result.messages[0].message_id).toBe(messageId)

    // Delete the message (chat_id target)
    const delRes = await app.handle(
      new Request("http://localhost/bot/deleteMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ chat_id: chatId, message_id: messageId }),
      }),
    )
    expect(delRes.status).toBe(200)
    const delJson = await delRes.json()
    expect(delJson.ok).toBe(true)

    // Deprecated alias remains supported for compatibility.
    const compatRes = await app.handle(
      new Request(`http://localhost/bot/getChat?peer_user_id=${human!.id}`, {
        method: "GET",
        headers: { Authorization: `Bearer ${token}` },
      }),
    )
    expect(compatRes.status).toBe(200)
    const compatJson = await compatRes.json()
    expect(compatJson.ok).toBe(true)
  })

  it("prefers POST JSON body values over query values when both are provided", async () => {
    const [bot] = await db
      .insert(users)
      .values({
        firstName: "BodyWinsBot",
        username: "bodywinsbot",
        bot: true,
        emailVerified: false,
        phoneVerified: false,
        pendingSetup: false,
      })
      .returning()

    const [human] = await db
      .insert(users)
      .values({
        firstName: "BodyWinsHuman",
        username: "bodywinshuman",
        bot: false,
        emailVerified: false,
        phoneVerified: false,
        pendingSetup: false,
      })
      .returning()

    const { token } = await generateToken(bot!.id)
    await SessionsModel.create({
      userId: bot!.id,
      tokenHash: hashToken(token),
      personalData: {},
      clientType: "api",
    })

    const chatRes = await app.handle(
      new Request(`http://localhost/bot/getChat?user_id=${human!.id}`, {
        method: "GET",
        headers: { Authorization: `Bearer ${token}` },
      }),
    )
    expect(chatRes.status).toBe(200)
    const chatJson = await chatRes.json()
    const chatId = chatJson.result.chat.chat_id as number

    const sendRes = await app.handle(
      new Request("http://localhost/bot/sendMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ chat_id: chatId, text: "initial" }),
      }),
    )
    expect(sendRes.status).toBe(200)
    const sendJson = await sendRes.json()
    const messageId = sendJson.result.message.message_id as number

    const editRes = await app.handle(
      new Request(
        `http://localhost/bot/editMessageText?chat_id=${chatId}&message_id=${messageId}&text=${encodeURIComponent("from-query")}`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${token}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            chat_id: chatId,
            message_id: messageId,
            text: "from-body",
          }),
        },
      ),
    )

    expect(editRes.status).toBe(200)
    const editJson = await editRes.json()
    expect(editJson.ok).toBe(true)
    expect(editJson.result.message.text).toBe("from-body")
  })
})
