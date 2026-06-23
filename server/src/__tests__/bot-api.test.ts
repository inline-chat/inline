import { describe, expect, it } from "bun:test"
import { app } from "../index"
import { db } from "@in/server/db"
import { users } from "@in/server/db/schema/users"
import { generateToken, hashToken } from "@in/server/utils/auth"
import { SessionsModel } from "@in/server/db/models/sessions"
import { setupTestLifecycle } from "./setup"

async function createBotSession(username: string) {
  const [bot] = await db
    .insert(users)
    .values({
      firstName: username,
      username,
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

  return { bot: bot!, token }
}

describe("Bot HTTP API", () => {
  setupTestLifecycle()

  it("documents only canonical Bot API fields", async () => {
    const res = await app.handle(new Request("http://localhost/bot-api-reference/json"))

    expect(res.status).toBe(200)
    const spec = await res.json()
    const text = JSON.stringify(spec)

    expect(text).toContain("chat_id")
    expect(text).toContain("user_id")
    expect(text).toContain("parse_markdown")
    expect(text).toContain("error_code")
    expect(text).not.toContain("peer_thread_id")
    expect(text).not.toContain("peer_user_id")
    expect(text).not.toContain("parseMarkdown")
    expect(text).not.toContain("thread_id")

    const richSourceInputs: any[] = []
    const collectRichSourceInputs = (value: unknown) => {
      if (!value || typeof value !== "object") return
      const record = value as Record<string, any>
      const properties = record["properties"]
      if (properties?.markdown && properties?.html && properties?.rich_message && properties?.rich_text) {
        richSourceInputs.push(record)
      }
      for (const child of Object.values(record)) {
        collectRichSourceInputs(child)
      }
    }
    collectRichSourceInputs(spec.paths?.["/bot/sendRichMessage"]?.post?.requestBody)
    expect(richSourceInputs.some((schema) => schema["properties"].direction)).toBe(true)

    const sendRichMessageDraftBody = JSON.stringify(spec.paths?.["/bot/sendRichMessageDraft"]?.post?.requestBody)
    expect(sendRichMessageDraftBody).toContain('"draft_id"')
    expect(sendRichMessageDraftBody).toContain('"maxLength":256')
  })

  it("returns documented Bot API errors for malformed requests", async () => {
    const { token } = await createBotSession("malformedbot")

    const res = await app.handle(
      new Request("http://localhost/bot/sendMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: "{",
      }),
    )

    expect(res.status).toBe(400)
    const json = await res.json()
    expect(json).toMatchObject({
      ok: false,
      error: "INVALID_ARGS",
      error_code: 400,
      description: "Validation error",
    })
    expect("errorCode" in json).toBe(false)
  })

  it("returns documented Bot API errors for legacy versioned sendMessage", async () => {
    const { token } = await createBotSession("legacyversionedbot")

    const res = await app.handle(
      new Request("http://localhost/v1/sendMessage20250509", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ text: "missing peer" }),
      }),
    )

    expect(res.status).toBe(400)
    const json = await res.json()
    expect(json).toMatchObject({
      ok: false,
      error: "PEER_INVALID",
      error_code: 400,
    })
    expect("errorCode" in json).toBe(false)
  })

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

    // Canonical DM targeting.
    const dmRes = await app.handle(
      new Request(`http://localhost/bot/getChat?user_id=${human!.id}`, {
        method: "GET",
        headers: { Authorization: `Bearer ${token}` },
      }),
    )
    expect(dmRes.status).toBe(200)
    const dmJson = await dmRes.json()
    expect(dmJson.ok).toBe(true)

    const aliasRes = await app.handle(
      new Request(`http://localhost/bot/getChat?peer_user_id=${human!.id}`, {
        method: "GET",
        headers: { Authorization: `Bearer ${token}` },
      }),
    )
    expect(aliasRes.status).toBe(200)
    const aliasJson = await aliasRes.json()
    expect(aliasJson.ok).toBe(true)

    const camelMarkdownRes = await app.handle(
      new Request("http://localhost/bot/sendMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ user_id: human!.id, text: "camel markdown alias", parseMarkdown: false }),
      }),
    )
    expect(camelMarkdownRes.status).toBe(200)
    const camelMarkdownJson = await camelMarkdownRes.json()
    expect(camelMarkdownJson.ok).toBe(true)
  })

  it("uses UTF-16 offsets for Bot API entity ranges with emoji", async () => {
    const { bot, token } = await createBotSession("utf16entitybot")

    const [human] = await db
      .insert(users)
      .values({
        firstName: "UtfHuman",
        username: "utfhuman",
        bot: false,
        emailVerified: false,
        phoneVerified: false,
        pendingSetup: false,
      })
      .returning()

    expect(bot).toBeDefined()
    expect(human).toBeDefined()

    const sendRes = await app.handle(
      new Request("http://localhost/bot/sendMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          text: "A😀BC",
          entities: [
            { type: "bold", offset: 1, length: 2 },
            { type: "italic", offset: 3, length: 2 },
          ],
        }),
      }),
    )

    expect(sendRes.status).toBe(200)
    const sendJson = await sendRes.json()
    expect(sendJson.ok).toBe(true)
    expect(sendJson.result.message.text).toBe("A😀BC")
    expect(sendJson.result.message.entities).toEqual([
      { type: "bold", offset: 1, length: 2 },
      { type: "italic", offset: 3, length: 2 },
    ])

    const invalidSplitStartRes = await app.handle(
      new Request("http://localhost/bot/sendMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          text: "A😀BC",
          entities: [{ type: "bold", offset: 2, length: 1 }],
        }),
      }),
    )

    expect(invalidSplitStartRes.status).toBe(400)

    const invalidSplitEndRes = await app.handle(
      new Request("http://localhost/bot/sendMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          text: "A😀BC",
          entities: [{ type: "bold", offset: 1, length: 1 }],
        }),
      }),
    )

    expect(invalidSplitEndRes.status).toBe(400)

    const invalidRes = await app.handle(
      new Request("http://localhost/bot/sendMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          text: "A😀BC",
          entities: [{ type: "bold", offset: 4, length: 2 }],
        }),
      }),
    )

    expect(invalidRes.status).toBe(400)

    const invalidEditRes = await app.handle(
      new Request("http://localhost/bot/editMessageText", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          message_id: sendJson.result.message.message_id,
          text: "A😀BC",
          entities: [{ type: "italic", offset: 2, length: 1 }],
        }),
      }),
    )

    expect(invalidEditRes.status).toBe(400)
  })

  it("parses inline markdown mention links on sendMessage when requested", async () => {
    const [bot] = await db
      .insert(users)
      .values({
        firstName: "MentionBot",
        username: "mentionbot",
        bot: true,
        emailVerified: false,
        phoneVerified: false,
        pendingSetup: false,
      })
      .returning()

    const [human] = await db
      .insert(users)
      .values({
        firstName: "Mentioned",
        username: "mentioned",
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

    const sendRes = await app.handle(
      new Request("http://localhost/bot/sendMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          text: `hi [@Mentioned](inline://user?id=${human!.id})`,
          parse_markdown: true,
        }),
      }),
    )

    expect(sendRes.status).toBe(200)
    const sendJson = await sendRes.json()
    expect(sendJson.ok).toBe(true)
    expect(sendJson.result.message.text).toBe("hi @Mentioned")
    expect(sendJson.result.message.entities).toEqual([
      {
        type: "mention",
        offset: 3,
        length: 10,
        user: {
          id: human!.id,
          is_bot: false,
          username: "mentioned",
          first_name: "Mentioned",
        },
      },
    ])
  })

  it("supports rich markdown on sendMessage and editMessageText", async () => {
    const { bot, token } = await createBotSession("richmarkdownbot")

    const [human] = await db
      .insert(users)
      .values({
        firstName: "RichHuman",
        username: "richhuman",
        bot: false,
        emailVerified: false,
        phoneVerified: false,
        pendingSetup: false,
      })
      .returning()

    expect(bot).toBeDefined()
    expect(human).toBeDefined()

    const sendRes = await app.handle(
      new Request("http://localhost/bot/sendMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          text: "## Title\n\nSee [docs](https://example.com/docs) and **ship**",
          parse_rich_markdown: true,
        }),
      }),
    )

    expect(sendRes.status).toBe(200)
    const sendJson = await sendRes.json()
    expect(sendJson.ok).toBe(true)
    expect(sendJson.result.message.text).toBe("Title\n\nSee docs and ship")
    expect(sendJson.result.message.rich_text).toMatchObject({
      fallback_text: "Title\n\nSee docs and ship",
      blocks: [
        { type: "heading", level: 2 },
        { type: "paragraph" },
      ],
    })
    expect(sendJson.result.message.entities.map((entity: any) => entity.type)).toContain("text_link")
    expect(sendJson.result.message.entities.map((entity: any) => entity.type)).toContain("bold")

    const inlineOnlyRes = await app.handle(
      new Request("http://localhost/bot/sendMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          text: "See [docs](https://example.com/docs), **ship**, <u>under</u>, and ~~struck~~",
          parse_rich_markdown: true,
        }),
      }),
    )

    expect(inlineOnlyRes.status).toBe(200)
    const inlineOnlyJson = await inlineOnlyRes.json()
    expect(inlineOnlyJson.ok).toBe(true)
    expect(inlineOnlyJson.result.message.text).toBe("See docs, ship, under, and struck")
    expect(inlineOnlyJson.result.message.rich_text).toBeUndefined()
    expect(inlineOnlyJson.result.message.entities.map((entity: any) => entity.type)).toEqual(
      expect.arrayContaining(["text_link", "bold", "underline", "strikethrough"]),
    )

    const unicodeRichRes = await app.handle(
      new Request("http://localhost/bot/sendMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          text: "### Hi 😀 [docs](https://example.com/docs) and **ship**",
          parse_rich_markdown: true,
        }),
      }),
    )

    expect(unicodeRichRes.status).toBe(200)
    const unicodeRichJson = await unicodeRichRes.json()
    expect(unicodeRichJson.ok).toBe(true)
    expect(unicodeRichJson.result.message.text).toBe("Hi 😀 docs and ship")
    expect(unicodeRichJson.result.message.rich_text).toMatchObject({
      fallback_text: "Hi 😀 docs and ship",
      blocks: [{ type: "heading", level: 3 }],
    })
    expect(unicodeRichJson.result.message.entities).toEqual(
      expect.arrayContaining([
        { type: "text_link", offset: 6, length: 4, url: "https://example.com/docs" },
        { type: "bold", offset: 15, length: 4 },
      ]),
    )

    const editRes = await app.handle(
      new Request("http://localhost/bot/editMessageText", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          message_id: sendJson.result.message.message_id,
          text: "### Edited\n\nUse `code`",
          parse_rich_markdown: true,
        }),
      }),
    )

    expect(editRes.status).toBe(200)
    const editJson = await editRes.json()
    expect(editJson.ok).toBe(true)
    expect(editJson.result.message.text).toBe("Edited\n\nUse code")
    expect(editJson.result.message.rich_text).toMatchObject({
      fallback_text: "Edited\n\nUse code",
      blocks: [
        { type: "heading", level: 3 },
        { type: "paragraph" },
      ],
    })
    expect(editJson.result.message.entities.map((entity: any) => entity.type)).toContain("code")

    const structuredRes = await app.handle(
      new Request("http://localhost/bot/sendMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          rich_text: {
            fallback_text: "",
            blocks: [
              {
                type: "heading",
                level: 2,
                text: [{ text: "Structured title", styles: ["bold"] }],
              },
              {
                type: "paragraph",
                text: [{ text: "Body copy" }],
              },
              {
                type: "list",
                items: [
                  { type: "list_item", checked: false, children: [{ type: "paragraph", text: [{ text: "Todo" }] }] },
                  { type: "list_item", checked: true, children: [{ type: "paragraph", text: [{ text: "Done" }] }] },
                ],
              },
            ],
          },
        }),
      }),
    )

    expect(structuredRes.status).toBe(200)
    const structuredJson = await structuredRes.json()
    expect(structuredJson.ok).toBe(true)
    expect(structuredJson.result.message.text).toBe("Structured title\n\nBody copy\n\n- [ ] Todo\n- [x] Done")
    expect(structuredJson.result.message.rich_text).toMatchObject({
      fallback_text: "Structured title\n\nBody copy\n\n- [ ] Todo\n- [x] Done",
      blocks: [
        { type: "heading", level: 2 },
        { type: "paragraph" },
        {
          type: "list",
          items: [
            { type: "list_item", checked: false },
            { type: "list_item", checked: true },
          ],
        },
      ],
    })
    expect(structuredJson.result.message.entities.map((entity: any) => entity.type)).toContain("bold")

    const sendRichRes = await app.handle(
      new Request("http://localhost/bot/sendRichMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          rich_message: {
            fallback_text: "",
            blocks: [
              {
                type: "paragraph",
                text: [{ text: "Sent via alias", styles: ["bold"] }],
              },
            ],
          },
        }),
      }),
    )

    expect(sendRichRes.status).toBe(200)
    const sendRichJson = await sendRichRes.json()
    expect(sendRichJson.ok).toBe(true)
    expect(sendRichJson.result.message.text).toBe("Sent via alias")
    expect(sendRichJson.result.message.rich_text).toMatchObject({
      fallback_text: "Sent via alias",
      blocks: [{ type: "paragraph" }],
    })
    expect(sendRichJson.result.message.entities.map((entity: any) => entity.type)).toContain("bold")

    const inputRichMarkdownRes = await app.handle(
      new Request("http://localhost/bot/sendRichMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          rich_message: {
            markdown: "## Wrapped\n\n/run",
            direction: "rtl",
            skip_entity_detection: true,
          },
        }),
      }),
    )

    expect(inputRichMarkdownRes.status).toBe(200)
    const inputRichMarkdownJson = await inputRichMarkdownRes.json()
    expect(inputRichMarkdownJson.ok).toBe(true)
    expect(inputRichMarkdownJson.result.message.text).toBe("Wrapped\n\n/run")
    expect(inputRichMarkdownJson.result.message.rich_text).toMatchObject({
      direction: "rtl",
      fallback_text: "Wrapped\n\n/run",
      blocks: [
        { type: "heading", level: 2 },
        { type: "paragraph" },
      ],
    })
    expect(inputRichMarkdownJson.result.message.entities ?? []).not.toEqual(
      expect.arrayContaining([expect.objectContaining({ type: "bot_command" })]),
    )

    const inputRichHtmlRes = await app.handle(
      new Request("http://localhost/bot/sendRichMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          rich_message: {
            html: '<h2>HTML Wrapped</h2><p>Read <a href="https://example.com/docs"><strong>docs</strong></a>, <u>under</u>, <s>struck</s>, and <tg-spoiler>secret</tg-spoiler></p>',
            is_rtl: true,
          },
        }),
      }),
    )

    expect(inputRichHtmlRes.status).toBe(200)
    const inputRichHtmlJson = await inputRichHtmlRes.json()
    expect(inputRichHtmlJson.ok).toBe(true)
    expect(inputRichHtmlJson.result.message.text).toBe("HTML Wrapped\n\nRead docs, under, struck, and secret")
    expect(inputRichHtmlJson.result.message.rich_text).toMatchObject({
      direction: "rtl",
      fallback_text: "HTML Wrapped\n\nRead docs, under, struck, and secret",
      blocks: [
        { type: "heading", level: 2 },
        { type: "paragraph" },
      ],
    })
    expect(inputRichHtmlJson.result.message.entities.map((entity: any) => entity.type)).toEqual(
      expect.arrayContaining(["text_link", "bold", "underline", "strikethrough"]),
    )

    const unicodeHtmlRes = await app.handle(
      new Request("http://localhost/bot/sendRichMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          rich_message: {
            html: '<p>Hi 😀 <a href="https://example.com/docs">docs</a> and <u>under</u></p>',
          },
        }),
      }),
    )

    expect(unicodeHtmlRes.status).toBe(200)
    const unicodeHtmlJson = await unicodeHtmlRes.json()
    expect(unicodeHtmlJson.ok).toBe(true)
    expect(unicodeHtmlJson.result.message.text).toBe("Hi 😀 docs and under")
    expect(unicodeHtmlJson.result.message.rich_text).toBeUndefined()
    expect(unicodeHtmlJson.result.message.entities).toEqual(
      expect.arrayContaining([
        { type: "text_link", offset: 6, length: 4, url: "https://example.com/docs" },
        { type: "underline", offset: 15, length: 5 },
      ]),
    )

    const inlineOnlyHtmlRes = await app.handle(
      new Request("http://localhost/bot/sendRichMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          rich_message: {
            html: '<p>Read <a href="https://example.com/docs"><strong>docs</strong></a>, <u>under</u>, and <s>struck</s></p>',
          },
        }),
      }),
    )

    expect(inlineOnlyHtmlRes.status).toBe(200)
    const inlineOnlyHtmlJson = await inlineOnlyHtmlRes.json()
    expect(inlineOnlyHtmlJson.ok).toBe(true)
    expect(inlineOnlyHtmlJson.result.message.text).toBe("Read docs, under, and struck")
    expect(inlineOnlyHtmlJson.result.message.rich_text).toBeUndefined()
    expect(inlineOnlyHtmlJson.result.message.entities.map((entity: any) => entity.type)).toEqual(
      expect.arrayContaining(["text_link", "bold", "underline", "strikethrough"]),
    )

    const unsafeHtmlRes = await app.handle(
      new Request("http://localhost/bot/sendRichMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          rich_message: {
            html: '<p onclick="bad()">Unsafe</p>',
          },
        }),
      }),
    )

    expect(unsafeHtmlRes.status).toBe(400)

    const finalThinkingRes = await app.handle(
      new Request("http://localhost/bot/sendRichMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          rich_message: {
            fallback_text: "",
            blocks: [
              {
                type: "thinking",
                initially_collapsed: true,
                children: [{ type: "paragraph", text: [{ text: "private reasoning" }] }],
              },
              {
                type: "paragraph",
                text: [{ text: "visible answer" }],
              },
            ],
          },
        }),
      }),
    )

    expect(finalThinkingRes.status).toBe(200)
    const finalThinkingJson = await finalThinkingRes.json()
    expect(finalThinkingJson.ok).toBe(true)
    expect(finalThinkingJson.result.message.text).toBe("visible answer")
    expect(finalThinkingJson.result.message.rich_text).toMatchObject({
      fallback_text: "visible answer",
      blocks: [{ type: "paragraph" }],
    })
    expect(finalThinkingJson.result.message.rich_text.blocks.map((block: any) => block.type)).not.toContain("thinking")

    const finalThinkingOnlyRes = await app.handle(
      new Request("http://localhost/bot/sendRichMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          rich_message: {
            fallback_text: "private reasoning",
            blocks: [
              {
                type: "thinking",
                initially_collapsed: true,
                children: [{ type: "paragraph", text: [{ text: "private reasoning" }] }],
              },
            ],
          },
        }),
      }),
    )

    expect(finalThinkingOnlyRes.status).toBe(400)

    const draftThinkingRes = await app.handle(
      new Request("http://localhost/bot/sendRichMessageDraft", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          draft_id: "bot-rich-draft-1",
          message_id: finalThinkingJson.result.message.message_id,
          rich_text: {
            fallback_text: "private reasoning",
            blocks: [
              {
                type: "thinking",
                initially_collapsed: true,
                children: [{ type: "paragraph", text: [{ text: "private reasoning" }] }],
              },
            ],
          },
        }),
      }),
    )

    expect(draftThinkingRes.status).toBe(200)
    const draftThinkingJson = await draftThinkingRes.json()
    expect(draftThinkingJson).toEqual({ ok: true, result: {} })

    const draftPublicMediaRes = await app.handle(
      new Request("http://localhost/bot/sendRichMessageDraft", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          draft_id: "bot-rich-draft-public-media",
          message_id: finalThinkingJson.result.message.message_id,
          rich_message: {
            fallback_text: "[Image: draft]",
            blocks: [
              {
                type: "photo",
                media: {
                  alt: "draft",
                  public_url: "https://example.com/draft.png",
                },
              },
            ],
          },
        }),
      }),
    )

    expect(draftPublicMediaRes.status).toBe(400)
    const draftPublicMediaJson = await draftPublicMediaRes.json()
    expect(draftPublicMediaJson.ok).toBe(false)

    const oversizedDraftIdRes = await app.handle(
      new Request("http://localhost/bot/sendRichMessageDraft", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          draft_id: "x".repeat(257),
          message_id: finalThinkingJson.result.message.message_id,
          clear: true,
        }),
      }),
    )

    expect(oversizedDraftIdRes.status).toBe(400)
    const oversizedDraftIdJson = await oversizedDraftIdRes.json()
    expect(oversizedDraftIdJson.ok).toBe(false)

    const clearDraftRes = await app.handle(
      new Request("http://localhost/bot/sendRichMessageDraft", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          draft_id: "bot-rich-draft-1",
          message_id: finalThinkingJson.result.message.message_id,
          clear: true,
        }),
      }),
    )

    expect(clearDraftRes.status).toBe(200)

    const ambiguousInputRes = await app.handle(
      new Request("http://localhost/bot/sendRichMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          rich_message: {
            markdown: "Ambiguous",
            rich_message: {
              fallback_text: "Ambiguous",
              blocks: [{ type: "paragraph", text: [{ text: "Ambiguous" }] }],
            },
          },
        }),
      }),
    )

    expect(ambiguousInputRes.status).toBe(400)

    const richOnlyEditRes = await app.handle(
      new Request("http://localhost/bot/editMessageText", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          message_id: structuredJson.result.message.message_id,
          rich_message: {
            fallback_text: "",
            blocks: [
              {
                type: "paragraph",
                text: [{ text: "Rich-only bot edit", styles: ["italic"] }],
              },
            ],
          },
        }),
      }),
    )

    expect(richOnlyEditRes.status).toBe(200)
    const richOnlyEditJson = await richOnlyEditRes.json()
    expect(richOnlyEditJson.ok).toBe(true)
    expect(richOnlyEditJson.result.message.text).toBe("Rich-only bot edit")
    expect(richOnlyEditJson.result.message.rich_text).toMatchObject({
      fallback_text: "Rich-only bot edit",
      blocks: [{ type: "paragraph" }],
    })
    expect(richOnlyEditJson.result.message.entities.map((entity: any) => entity.type)).toContain("italic")
  })

  it("rejects oversized generated rich fallback through the public Bot API", async () => {
    const { token } = await createBotSession("richoversizebot")

    const [human] = await db
      .insert(users)
      .values({
        firstName: "RichOversizeHuman",
        username: "richoversizehuman",
        bot: false,
        emailVerified: false,
        phoneVerified: false,
        pendingSetup: false,
      })
      .returning()

    expect(human).toBeDefined()

    const res = await app.handle(
      new Request("http://localhost/bot/sendRichMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          rich_message: {
            fallback_text: "",
            blocks: [
              {
                type: "paragraph",
                text: [{ text: "x".repeat(32_767) }],
              },
              {
                type: "paragraph",
                text: [{ text: "y" }],
              },
            ],
          },
        }),
      }),
    )

    expect(res.status).toBe(400)
    const json = await res.json()
    expect(json).toMatchObject({
      ok: false,
      error_code: 400,
    })
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

  it("manages bot commands through getMyCommands, setMyCommands, and deleteMyCommands", async () => {
    const [bot] = await db
      .insert(users)
      .values({
        firstName: "CommandsBot",
        username: "commandsbot",
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

    const initialRes = await app.handle(
      new Request("http://localhost/bot/getMyCommands", {
        method: "GET",
        headers: { Authorization: `Bearer ${token}` },
      }),
    )

    expect(initialRes.status).toBe(200)
    const initialJson = await initialRes.json()
    expect(initialJson).toEqual({
      ok: true,
      result: {
        commands: [],
      },
    })

    const setRes = await app.handle(
      new Request("http://localhost/bot/setMyCommands", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          commands: [
            { command: "start", description: "Start the bot", sort_order: 1 },
            { command: "help", description: "Show help", sort_order: 2 },
          ],
        }),
      }),
    )

    expect(setRes.status).toBe(200)
    const setJson = await setRes.json()
    expect(setJson).toEqual({
      ok: true,
      result: {},
    })

    const afterSetRes = await app.handle(
      new Request("http://localhost/bot/getMyCommands", {
        method: "GET",
        headers: { Authorization: `Bearer ${token}` },
      }),
    )

    expect(afterSetRes.status).toBe(200)
    const afterSetJson = await afterSetRes.json()
    expect(afterSetJson).toEqual({
      ok: true,
      result: {
        commands: [
          { command: "start", description: "Start the bot", sort_order: 1 },
          { command: "help", description: "Show help", sort_order: 2 },
        ],
      },
    })

    const deleteRes = await app.handle(
      new Request("http://localhost/bot/deleteMyCommands", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
        },
      }),
    )

    expect(deleteRes.status).toBe(200)
    const deleteJson = await deleteRes.json()
    expect(deleteJson).toEqual({
      ok: true,
      result: {},
    })

    const afterDeleteRes = await app.handle(
      new Request("http://localhost/bot/getMyCommands", {
        method: "GET",
        headers: { Authorization: `Bearer ${token}` },
      }),
    )

    expect(afterDeleteRes.status).toBe(200)
    const afterDeleteJson = await afterDeleteRes.json()
    expect(afterDeleteJson).toEqual({
      ok: true,
      result: {
        commands: [],
      },
    })
  })

  it("rejects invalid command payloads for setMyCommands", async () => {
    const [bot] = await db
      .insert(users)
      .values({
        firstName: "InvalidCommandsBot",
        username: "invalidcommandsbot",
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

    const invalidRes = await app.handle(
      new Request("http://localhost/bot/setMyCommands", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          commands: [
            { command: "Start", description: "Uppercase command should fail" },
          ],
        }),
      }),
    )

    expect(invalidRes.status).toBe(400)
    const invalidJson = await invalidRes.json()
    expect(invalidJson.ok).toBe(false)
    expect(invalidJson.error_code).toBe(400)
  })

  it("rejects duplicate command payloads for setMyCommands", async () => {
    const [bot] = await db
      .insert(users)
      .values({
        firstName: "DuplicateCommandsBot",
        username: "duplicatecommandsbot",
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

    const duplicateRes = await app.handle(
      new Request("http://localhost/bot/setMyCommands", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          commands: [
            { command: "start", description: "Start the bot" },
            { command: "start", description: "Duplicate start" },
          ],
        }),
      }),
    )

    expect(duplicateRes.status).toBe(400)
    const duplicateJson = await duplicateRes.json()
    expect(duplicateJson.ok).toBe(false)
    expect(duplicateJson.error_code).toBe(400)
  })
})
