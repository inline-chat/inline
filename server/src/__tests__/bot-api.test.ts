import { describe, expect, it } from "bun:test"
import { app } from "../legacyServer"
import { db } from "@in/server/db"
import { users } from "@in/server/db/schema/users"
import { generateToken, hashToken } from "@in/server/utils/auth"
import { SessionsModel } from "@in/server/db/models/sessions"
import { MessageModel } from "@in/server/db/models/messages"
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

  it("manages the authenticated bot's Agent specializations", async () => {
    const { token } = await createBotSession("agentapibot")
    const headers = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }

    const createdResponse = await app.handle(new Request("http://localhost/bot/createAgent", {
      method: "POST",
      headers,
      body: JSON.stringify({
        name: "Data Analyst",
        emoji: "📊",
        description: "Analyzes product metrics",
        skill_key: "analytics",
      }),
    }))
    expect(createdResponse.status).toBe(200)
    const created = await createdResponse.json()
    expect(created).toMatchObject({
      ok: true,
      result: {
        agent: {
          name: "Data Analyst",
          emoji: "📊",
          description: "Analyzes product metrics",
          skill_key: "analytics",
        },
      },
    })
    const agentId = created.result.agent.id

    const listedResponse = await app.handle(new Request("http://localhost/bot/getMyAgents", { headers }))
    expect(await listedResponse.json()).toMatchObject({
      ok: true,
      result: { agents: [{ id: agentId, name: "Data Analyst" }] },
    })

    const updatedResponse = await app.handle(new Request("http://localhost/bot/updateAgent", {
      method: "POST",
      headers,
      body: JSON.stringify({ agent_id: agentId, name: "Research Analyst", description: "" }),
    }))
    expect(await updatedResponse.json()).toMatchObject({
      ok: true,
      result: { agent: { id: agentId, name: "Research Analyst" } },
    })

    const deletedResponse = await app.handle(new Request("http://localhost/bot/deleteAgent", {
      method: "POST",
      headers,
      body: JSON.stringify({ agent_id: agentId }),
    }))
    expect(await deletedResponse.json()).toEqual({ ok: true, result: { agent_id: agentId } })

    const missingResponse = await app.handle(new Request(
      `http://localhost/bot/getAgent?agent_id=${agentId}`,
      { headers },
    ))
    expect(missingResponse.status).toBe(400)
    expect(await missingResponse.json()).toMatchObject({
      ok: false,
      error: "BAD_REQUEST",
      error_code: 400,
    })
  })

  it("persists one update stream across polling and webhook settings", async () => {
    const { token } = await createBotSession("deliverybot")
    const auth = { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }

    const updates = await app.handle(new Request(
      "http://localhost/bot/getUpdates?timeout=0&allowed_updates=%5B%22message%22%2C%22bot_participation%22%5D",
      { headers: auth },
    ))
    expect(updates.status).toBe(200)
    expect(await updates.json()).toEqual({ ok: true, result: [] })

    const set = await app.handle(new Request("http://localhost/bot/setWebhook", {
      method: "POST",
      headers: auth,
      body: JSON.stringify({ url: "", message_trigger: "all" }),
    }))
    expect(await set.json()).toEqual({ ok: true, result: true })

    const info = await app.handle(new Request("http://localhost/bot/getWebhookInfo", { headers: auth }))
    expect(await info.json()).toMatchObject({
      ok: true,
      result: {
        url: "",
        pending_update_count: 0,
        message_trigger: "all",
        allowed_updates: ["message", "bot_participation"],
        dropped_update_count: 0,
      },
    })
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

    const [additionalParticipant] = await db
      .insert(users)
      .values({
        firstName: "Additional Participant",
        username: "additionalparticipant",
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
          text: "**hello**",
        }),
      }),
    )
    expect(sendRes.status).toBe(200)
    const sendJson = await sendRes.json()
    expect(sendJson.ok).toBe(true)
    const messageId = sendJson.result.message.message_id as number
    const storedMessage = await MessageModel.getMessage(messageId, chatId)
    expect(storedMessage.entities).toBeTruthy()
    expect(storedMessage.blockContent).toBeTruthy()
    expect(sendJson.result.message.entities).toBeUndefined()
    expect(sendJson.result.message.rich_message).toEqual({
      blocks: [{
        type: "paragraph",
        text: { type: "bold", text: "hello" },
      }],
    })
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
    expect(chatAfterSendJson.result.chat.last_message.entities).toBeUndefined()
    expect(chatAfterSendJson.result.chat.last_message.rich_message).toEqual({
      blocks: [{
        type: "paragraph",
        text: { type: "bold", text: "hello" },
      }],
    })

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
          text: "*edited*",
        }),
      }),
    )
    expect(editRes.status).toBe(200)
    const editJson = await editRes.json()
    expect(editJson.ok).toBe(true)
    expect(editJson.result.message.text).toBe("edited")
    const storedEdit = await MessageModel.getMessage(messageId, chatId)
    expect(storedEdit.entities).toBeTruthy()
    expect(storedEdit.blockContent).toBeTruthy()
    expect(editJson.result.message.entities).toBeUndefined()
    expect(editJson.result.message.rich_message).toEqual({
      blocks: [{
        type: "paragraph",
        text: { type: "italic", text: "edited" },
      }],
    })

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
    expect(histJson.result.messages[0].entities).toBeUndefined()
    expect(histJson.result.messages[0].rich_message).toEqual({
      blocks: [{
        type: "paragraph",
        text: { type: "italic", text: "edited" },
      }],
    })

    const exactRes = await app.handle(
      new Request("http://localhost/bot/getMessages", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ chat_id: chatId, message_ids: [messageId] }),
      }),
    )
    expect(exactRes.status).toBe(200)
    const exactJson = await exactRes.json()
    expect(exactJson.result.messages.map((message: any) => message.message_id)).toEqual([messageId])
    expect(exactJson.result.messages[0].edit_date).toBeUndefined()
    expect(exactJson.result.messages[0].peer_id).toEqual({ user_id: human!.id })
    expect(exactJson.result.messages[0].chat).toBeUndefined()

    const searchRes = await app.handle(
      new Request("http://localhost/bot/searchMessages", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ chat_id: chatId, query: "edited" }),
      }),
    )
    expect(searchRes.status).toBe(200)
    const searchJson = await searchRes.json()
    expect(searchJson.result.messages[0].message_id).toBe(messageId)

    const replyThreadRes = await app.handle(
      new Request("http://localhost/bot/createReplyThread", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ chat_id: chatId, message_id: messageId }),
      }),
    )
    expect(replyThreadRes.status).toBe(200)
    const replyThreadJson = await replyThreadRes.json()
    expect(replyThreadJson.result.chat).toMatchObject({
      type: "thread",
      parent_chat_id: chatId,
      parent_message: {
        message_id: messageId,
      },
    })
    expect(replyThreadJson.result.chat).not.toHaveProperty("parent_message_id")
    expect(replyThreadJson.result.chat.parent_message).toHaveProperty("peer_id")
    expect(replyThreadJson.result.chat.parent_message).not.toHaveProperty("chat")
    expect(replyThreadJson.result.chat.parent_message).not.toHaveProperty("reply_to_message")

    const threadRes = await app.handle(
      new Request("http://localhost/bot/createThread", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          title: "Bot context thread",
          participants: [human!.id],
        }),
      }),
    )
    expect(threadRes.status).toBe(200)
    const threadJson = await threadRes.json()
    expect(threadJson.result.chat.type).toBe("thread")
    const threadChatId = threadJson.result.chat.chat_id as number

    const firstThreadMessageRes = await app.handle(
      new Request("http://localhost/bot/sendMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          chat_id: threadChatId,
          text: `Hello [@Human](inline://user/${human!.id})`,
        }),
      }),
    )
    expect(firstThreadMessageRes.status).toBe(200)
    const firstThreadMessageJson = await firstThreadMessageRes.json()
    expect(firstThreadMessageJson.result.message.chat.chat_id).toBe(threadChatId)
    expect(firstThreadMessageJson.result.message.entities).toBeUndefined()
    expect(firstThreadMessageJson.result.message.rich_message).toEqual({
      blocks: [{
        type: "paragraph",
        text: [
          "Hello ",
          {
            type: "text_mention",
            text: "@Human",
            user: expect.objectContaining({ id: human!.id }),
          },
        ],
      }],
    })

    const addParticipantRes = await app.handle(
      new Request("http://localhost/bot/addThreadParticipant", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ chat_id: threadChatId, user_id: additionalParticipant!.id }),
      }),
    )
    expect(addParticipantRes.status).toBe(200)

    const addedParticipantRes = await app.handle(
      new Request(
        `http://localhost/bot/getChatParticipant?chat_id=${threadChatId}&user_id=${additionalParticipant!.id}`,
        { headers: { Authorization: `Bearer ${token}` } },
      ),
    )
    expect(addedParticipantRes.status).toBe(200)
    expect((await addedParticipantRes.json()).result.participant.user.id).toBe(additionalParticipant!.id)

    const removeParticipantRes = await app.handle(
      new Request("http://localhost/bot/removeThreadParticipant", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ chat_id: threadChatId, user_id: additionalParticipant!.id }),
      }),
    )
    expect(removeParticipantRes.status).toBe(200)

    const removeBotRes = await app.handle(
      new Request("http://localhost/bot/removeThreadParticipant", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ chat_id: threadChatId, user_id: bot!.id }),
      }),
    )
    expect(removeBotRes.status).toBe(400)

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
        body: JSON.stringify({
          user_id: human!.id,
          text: "camel **markdown** alias",
          parseMarkdown: false,
        }),
      }),
    )
    expect(camelMarkdownRes.status).toBe(200)
    const camelMarkdownJson = await camelMarkdownRes.json()
    expect(camelMarkdownJson.ok).toBe(true)
    expect(camelMarkdownJson.result.message.text).toBe("camel **markdown** alias")
    expect(camelMarkdownJson.result.message.entities).toBeUndefined()

    const canonicalMarkdownRes = await app.handle(
      new Request("http://localhost/bot/sendMessage", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          user_id: human!.id,
          text: "canonical **markdown** flag",
          parse_markdown: false,
        }),
      }),
    )
    expect(canonicalMarkdownRes.status).toBe(200)
    const canonicalMarkdownJson = await canonicalMarkdownRes.json()
    expect(canonicalMarkdownJson.ok).toBe(true)
    expect(canonicalMarkdownJson.result.message.text).toBe("canonical **markdown** flag")
    expect(canonicalMarkdownJson.result.message.entities).toBeUndefined()
  })

  it("parses inline markdown mention links on sendMessage by default", async () => {
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
        }),
      }),
    )

    expect(sendRes.status).toBe(200)
    const sendJson = await sendRes.json()
    expect(sendJson.ok).toBe(true)
    expect(sendJson.result.message.text).toBe("hi @Mentioned")
    expect(sendJson.result.message.entities).toBeUndefined()
    expect(sendJson.result.message.rich_message).toEqual({
      blocks: [{
        type: "paragraph",
        text: [
          "hi ",
          {
            type: "text_mention",
            text: "@Mentioned",
            user: {
              id: human!.id,
              is_bot: false,
              username: "mentioned",
              first_name: "Mentioned",
            },
          },
        ],
      }],
    })

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
          text: "updated **Markdown**",
        }),
      }),
    )

    expect(editRes.status).toBe(200)
    const editJson = await editRes.json()
    expect(editJson.ok).toBe(true)
    expect(editJson.result.message.text).toBe("updated Markdown")
    expect(editJson.result.message.entities).toBeUndefined()
    expect(editJson.result.message.rich_message).toEqual({
      blocks: [{
        type: "paragraph",
        text: [
          "updated ",
          { type: "bold", text: "Markdown" },
        ],
      }],
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

  it("publishes and removes the authenticated harness skill catalog", async () => {
    const [bot] = await db
      .insert(users)
      .values({
        firstName: "SkillsBot",
        username: "skillsbot",
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
    const headers = {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    }

    const setRes = await app.handle(
      new Request("http://localhost/bot/setMySkills", {
        method: "POST",
        headers,
        body: JSON.stringify({
          skills: [
            { key: "data-analysis", name: "Data Analysis", sort_order: 20 },
            { key: "research", name: "Research", description: "Research with sources", sort_order: 10 },
          ],
        }),
      }),
    )
    expect(setRes.status).toBe(200)

    const getRes = await app.handle(
      new Request("http://localhost/bot/getMySkills", {
        headers: { Authorization: `Bearer ${token}` },
      }),
    )
    expect(getRes.status).toBe(200)
    expect(await getRes.json()).toEqual({
      ok: true,
      result: {
        skills: [
          { key: "research", name: "Research", description: "Research with sources", sort_order: 10 },
          { key: "data-analysis", name: "Data Analysis", sort_order: 20 },
        ],
      },
    })

    const duplicateRes = await app.handle(
      new Request("http://localhost/bot/setMySkills", {
        method: "POST",
        headers,
        body: JSON.stringify({
          skills: [
            { key: "research", name: "Research" },
            { key: "research", name: "Duplicate" },
          ],
        }),
      }),
    )
    expect(duplicateRes.status).toBe(400)

    const deleteRes = await app.handle(
      new Request("http://localhost/bot/deleteMySkills", {
        method: "POST",
        headers: { Authorization: `Bearer ${token}` },
      }),
    )
    expect(deleteRes.status).toBe(200)
    expect(await deleteRes.json()).toEqual({ ok: true, result: {} })
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
