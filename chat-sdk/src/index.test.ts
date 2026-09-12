import { afterEach, describe, expect, test } from "bun:test"
import { Chat, emoji, RateLimitError, Card, CardText, Actions, Button, LinkButton } from "chat"
import { createMemoryState } from "@chat-adapter/state-memory"
import type { BotMessage } from "@inline-chat/bot-api-types"
import { markdownFixture } from "../test-fixtures/markdown.js"
import { createInlineAdapter } from "./index.js"

const user = { id: 21, is_bot: false, first_name: "Human" }
function message(chatId = 10, messageId = 1): BotMessage {
  return {
    message_id: messageId,
    peer_id: { chat_id: chatId },
    chat: { chat_id: chatId, type: "thread" },
    from_id: user.id,
    from: user,
    date: 1_800_000_000,
    text: "hello",
    entities: [],
  }
}
const chats: Chat[] = []
afterEach(async () => {
  await Promise.all(chats.splice(0).map((chat) => chat.shutdown()))
})

async function setup(override?: (method: string, body: Record<string, unknown>) => unknown) {
  const calls: { method: string; body: Record<string, unknown>; headers: Headers }[] = []
  const adapter = createInlineAdapter({
    token: "test-token",
    webhookSecret: "test-secret",
    fetch: (async (input: string | URL | Request, init?: RequestInit) => {
      const url = new URL(String(input))
      const method = url.pathname.split("/").at(-1)!
      const body =
        init?.body instanceof FormData
          ? Object.fromEntries(init.body.entries())
          : init?.body
          ? JSON.parse(String(init.body))
          : Object.fromEntries(url.searchParams.entries())
      calls.push({ method, body, headers: new Headers(init?.headers) })
      const custom = override?.(method, body)
      const output =
        custom ??
        (method === "getMe"
          ? { user: { id: 99, is_bot: true, username: "helper" } }
          : method === "getChat"
          ? { chat: { chat_id: 10, type: "thread", title: "Team" } }
          : method === "uploadFile"
          ? { file: { file_id: "uploaded" } }
          : method === "sendMessage" || method === "editMessageText"
          ? { message: { ...message(), text: body.text } }
          : {})
      return Response.json({ ok: true, result: output })
    }) as typeof fetch,
  })
  const chat = new Chat({
    userName: "helper",
    adapters: { inline: adapter },
    state: createMemoryState(),
    logger: "silent",
  })
  chats.push(chat)
  await chat.initialize()
  async function webhook(
    update: unknown,
    secret = "test-secret",
    options?: { waitUntil: (task: Promise<unknown>) => void },
  ) {
    return adapter.handleWebhook(
      new Request("https://example.com/webhook", {
        method: "POST",
        headers: { "x-inline-bot-api-secret-token": secret },
        body: JSON.stringify(update),
      }),
      options,
    )
  }
  return { chat, adapter, calls, webhook }
}

describe("Inline adapter", () => {
  test("authenticates before parsing or dispatching, rejects malformed JSON", async () => {
    const { webhook, adapter } = await setup()
    expect((await webhook({ update_id: 1, message: message() }, "wrong")).status).toBe(401)
    expect((await webhook({})).status).toBe(400)
    expect((await webhook({ update_id: 1, message: {} })).status).toBe(400)
    expect(
      (await webhook({ update_id: 1, message: { ...message(), peer_id: { user_id: 1, chat_id: 2 } } })).status,
    ).toBe(400)
    expect(
      (
        await adapter.handleWebhook(
          new Request("https://example.com", {
            method: "POST",
            headers: { "x-inline-bot-api-secret-token": "test-secret" },
            body: "{",
          }),
        )
      ).status,
    ).toBe(400)
  })

  test("scopes message IDs across conversations, deduplicates retries, and routes subscribed followups", async () => {
    const { chat, webhook } = await setup()
    const mentions: string[] = [],
      followups: string[] = []
    chat.onNewMention(async (thread) => {
      mentions.push(thread.id)
      await thread.subscribe()
    })
    chat.onSubscribedMessage(async (_thread, msg) => {
      followups.push(msg.id)
    })
    const first = { update_id: 1, activation_reason: "mention", message: message(10, 1) }
    await webhook(first)
    await webhook(first)
    await webhook({ ...first, update_id: 2, message: message(11, 1) })
    await webhook({ update_id: 3, activation_reason: "all", message: message(10, 2) })
    expect(mentions).toEqual(["inline:chat:10", "inline:chat:11"])
    expect(followups).toEqual(["inline:chat:10:2"])
  })

  test("routes DMs, ignores own messages, and dispatches edits separately", async () => {
    const { chat, webhook } = await setup()
    let dms = 0,
      edits = 0
    chat.onDirectMessage(async () => {
      dms++
    })
    chat.onMessageUpdated(async () => {
      edits++
    })
    const dm = { ...message(), peer_id: { user_id: 21 }, chat: { chat_id: 50, type: "user" } }
    await webhook({ update_id: 1, message: dm })
    await webhook({ update_id: 2, message: { ...dm, message_id: 2, from: { id: 99, is_bot: true } } })
    await webhook({ update_id: 3, edited_message: { ...dm, text: "edited", edit_date: 1_800_000_001 } })
    expect(dms).toBe(1)
    expect(edits).toBe(1)
  })

  test("preserves literal text, explicitly enables markdown, and rejects cross-chat message operations", async () => {
    const { adapter, calls } = await setup()
    const sent = await adapter.postMessage("inline:chat:10", { raw: "*literal*" })
    expect(sent.id).toBe("inline:chat:10:1")
    expect(calls.at(-1)?.body).toEqual({ chat_id: "10", text: "*literal*", parse_markdown: false })
    expect(calls.at(-1)?.headers.get("authorization")).toBe("Bearer test-token")
    await adapter.editMessage("inline:chat:10", sent.id, { markdown: "**bold**" })
    expect(calls.at(-1)?.body.message_id).toBe("1")
    expect(calls.at(-1)?.body.parse_markdown).toBe(true)
    await expect(adapter.deleteMessage("inline:chat:11", sent.id)).rejects.toThrow("different conversation")
    await adapter.reply("inline:chat:10", sent.id, "reply")
    expect(calls.at(-1)?.body.reply_to_message_id).toBe("1")
  })

  test("returns chronologically ordered backward pages with native cursors", async () => {
    const { adapter, calls } = await setup((method) =>
      method === "getChatHistory" ? { messages: [message(10, 3), message(10, 2)] } : undefined,
    )
    const page = await adapter.fetchMessages("inline:chat:10", { limit: 2 })
    expect(page.messages.map((item) => item.id)).toEqual(["inline:chat:10:2", "inline:chat:10:3"])
    expect(page.nextCursor).toBe("2")
    await adapter.fetchMessages("inline:chat:10", { limit: 2, cursor: page.nextCursor })
    expect(calls.at(-1)?.body.offset_message_id).toBe("2")
    await expect(adapter.fetchMessages("inline:chat:10", { direction: "forward" })).rejects.toThrow("backward")
  })

  test("renders real callback buttons, acknowledges and deduplicates actions", async () => {
    const { adapter, chat, calls, webhook } = await setup()
    await adapter.postMessage(
      "inline:chat:10",
      Card({
        title: "Review",
        children: [CardText("Approve?"), Actions([Button({ id: "approve", label: "Approve", value: "yes" })])],
      }),
    )
    expect(calls.at(-1)?.body.actions).toEqual([
      [{ type: "callback", action_id: "approve", text: "Approve", callback_data: "yes" }],
    ])
    const values: unknown[] = []
    chat.onAction("approve", async (event) => {
      values.push([event.messageId, event.value])
    })
    const update = {
      update_id: 1,
      message_action: {
        interaction_id: 7,
        chat: message().chat,
        message_id: 1,
        actor: user,
        date: 1_800_000_000,
        action: { action_id: "approve", callback_data: "yes" },
      },
    }
    await webhook(update)
    await webhook(update)
    expect(values).toEqual([["inline:chat:10:1", "yes"]])
    expect(calls.filter((call) => call.method === "answerMessageAction")).toHaveLength(1)
    await adapter.postMessage(
      "inline:chat:10",
      Card({ children: [Actions([LinkButton({ label: "Link", url: "https://example.com" })])] }),
    )
    expect(calls.at(-1)?.body.text).toContain("[Link](https://example.com)")
    expect(calls.at(-1)?.body.parse_markdown).toBe(true)
  })

  test("normalizes reaction deltas and deduplicates event retries", async () => {
    const { chat, webhook, adapter, calls } = await setup()
    const events: string[] = []
    chat.onReaction(async (event) => {
      events.push(`${event.added}:${event.emoji.name}`)
    })
    const update = {
      update_id: 1,
      message_reaction: {
        chat: message().chat,
        message_id: 1,
        actor: user,
        date: 1_800_000_000,
        old_reaction: [{ emoji: "❤️" }],
        new_reaction: [{ emoji: "👍" }],
      },
    }
    await webhook(update)
    await webhook(update)
    expect(events).toEqual(["true:thumbs_up", "false:heart"])
    await adapter.addReaction("inline:chat:10", "inline:chat:10:1", emoji.thumbs_up)
    expect(calls.at(-1)?.body.emoji).toBe("👍")
  })

  test("rejects multiple files and media edits before uploading anything", async () => {
    const { adapter, calls } = await setup()
    const files = [
      { filename: "one.txt", data: Buffer.from("one") },
      { filename: "two.txt", data: Buffer.from("two") },
    ]
    const before = calls.length
    await expect(adapter.postMessage("inline:chat:10", { markdown: "Files", files })).rejects.toThrow("one file per message")
    await expect(adapter.editMessage("inline:chat:10", "inline:chat:10:1", { markdown: "File", files: files.slice(0, 1) })).rejects.toThrow("replacing message attachments")
    expect(calls).toHaveLength(before)
  })

  test("uploads one file before sending and exposes refreshable inbound attachments", async () => {
    const { adapter, calls } = await setup()
    await adapter.postMessage("inline:chat:10", {
      raw: "report",
      files: [{ filename: "report.txt", data: Buffer.from("hello") }],
    })
    expect(calls.at(-2)?.method).toBe("uploadFile")
    expect(calls.at(-1)?.body.media).toEqual({ type: "document", file_id: "uploaded" })
    const parsed = adapter.parseMessage({
      ...message(),
      media: {
        type: "document",
        file: { file_id: "doc", download_url: "https://signed.example/secret", file_name: "report.txt" },
      },
    })
    expect(parsed.attachments[0]?.fetchMetadata).toEqual({ fileId: "doc" })
    expect(parsed.attachments[0]?.url).toBeUndefined()
    expect(typeof parsed.attachments[0]?.fetchData).toBe("function")
    await expect(
      adapter.editMessage("inline:chat:10", "inline:chat:10:1", {
        raw: "x",
        files: [{ filename: "x", data: Buffer.from("x") }],
      }),
    ).rejects.toThrow("replacing message attachments")
  })

  test("waitUntil returns before the handler completes", async () => {
    const { chat, webhook } = await setup()
    let finish!: () => void
    const gate = new Promise<void>((resolve) => {
      finish = resolve
    })
    chat.onNewMention(async () => {
      await gate
    })
    const tasks: Promise<unknown>[] = []
    const response = await webhook({ update_id: 1, activation_reason: "mention", message: message() }, "test-secret", {
      waitUntil: (task) => {
        tasks.push(task)
      },
    })
    expect(response.status).toBe(200)
    expect(tasks).toHaveLength(1)
    finish()
    await Promise.all(tasks)
  })

  test("streams through Chat SDK's post/edit fallback", async () => {
    const { chat, webhook, calls } = await setup()
    chat.onNewMention(async (thread) => {
      async function* stream() {
        yield "Hello "
        yield "world"
      }
      await thread.post(stream())
    })
    await webhook({ update_id: 1, activation_reason: "mention", message: message() })
    const sends = calls.filter((call) => call.method === "sendMessage" || call.method === "editMessageText")
    expect(sends[0]?.method).toBe("sendMessage")
    expect(sends.at(-1)?.body.text).toContain("Hello world")
  })

  test("downloads fresh attachment URLs without forwarding bot credentials", async () => {
    const seen: { url: string; headers: Headers }[] = []
    const adapter = createInlineAdapter({
      token: "token",
      webhookSecret: "secret",
      fetch: (async (input: string | URL | Request, init?: RequestInit) => {
        const url = String(input)
        seen.push({ url, headers: new Headers(init?.headers) })
        return url.includes("/getFile")
          ? Response.json({
              ok: true,
              result: { file: { file_id: "doc", download_url: "https://files.example/fresh" } },
            })
          : new Response("download")
      }) as typeof fetch,
    })
    const attachment = adapter.parseMessage({ ...message(), media: { type: "document", file: { file_id: "doc" } } })
      .attachments[0]!
    const rehydrated = adapter.rehydrateAttachment(JSON.parse(JSON.stringify(attachment)))
    const data = await rehydrated.fetchData!()
    expect(new TextDecoder().decode(data)).toBe("download")
    expect(seen[0]?.headers.get("authorization")).toBe("Bearer token")
    expect(seen[1]?.headers.has("authorization")).toBe(false)
    expect(seen[1]?.url).toBe("https://files.example/fresh")
  })

  test("slash commands dispatch once in groups and DMs, with working channel replies", async () => {
    const { chat, webhook, calls } = await setup()
    const handled: unknown[] = []
    let messages = 0
    chat.onDirectMessage(async () => {
      messages++
    })
    chat.onNewMention(async () => {
      messages++
    })
    chat.onSlashCommand("/help", async (event) => {
      handled.push([event.command, event.text, event.channel.id])
      await event.channel.post("**Help**")
    })
    const update = {
      update_id: 50,
      activation_reason: "command",
      message: { ...message(), text: "/help@helper   topic" },
    }
    await webhook(update)
    await webhook(update)
    expect(handled).toEqual([["/help", "topic", "inline:chat:10"]])
    expect(calls.at(-1)?.body.chat_id).toBe("10")
    await webhook({ ...update, update_id: 51, message: { ...message(), peer_id: { user_id: 21 }, text: "/help dm" } })
    expect(handled).toHaveLength(2)
    expect(calls.at(-1)?.body.user_id).toBe("21")
    expect(calls.at(-1)?.body.parse_markdown).toBe(true)
    await webhook({ ...update, update_id: 52, message: { ...message(), message_id: 3, text: "/help@someone_else" } })
    expect(handled).toHaveLength(2)
    expect(messages).toBe(0)
  })

  test("outbound DMs and channel history use explicit Inline peers", async () => {
    const { chat, adapter, calls } = await setup((method) =>
      method === "getChatHistory" ? { messages: [] } : undefined,
    )
    const dm = chat.thread(await adapter.openDM("21"))
    await dm.post("**Hello**")
    expect(calls.at(-1)?.body.user_id).toBe("21")
    expect(calls.at(-1)?.body.parse_markdown).toBe(true)
    await adapter.fetchChannelMessages("inline:user:21")
    expect(calls.at(-1)?.body.user_id).toBe("21")
    expect((await adapter.fetchChannelInfo("inline:user:21")).isDM).toBe(true)
  })

  test("rich Markdown reaches sends, edits, replies, captions and streaming unchanged", async () => {
    const { adapter, chat, calls, webhook } = await setup()
    await adapter.postMessage("inline:chat:10", markdownFixture)
    expect(calls.at(-1)?.body.text).toBe(markdownFixture)
    await adapter.editMessage("inline:chat:10", "inline:chat:10:1", { markdown: markdownFixture })
    expect(calls.at(-1)?.body.text).toBe(markdownFixture)
    await adapter.reply("inline:chat:10", "inline:chat:10:1", markdownFixture)
    expect(calls.at(-1)?.body.text).toBe(markdownFixture)
    await adapter.postMessage("inline:chat:10", {
      markdown: markdownFixture,
      files: [{ filename: "x", data: Buffer.from("x") }],
    })
    expect(calls.at(-1)?.body.text).toBe(markdownFixture)
    chat.onNewMention(async (thread) => {
      async function* stream() {
        yield markdownFixture.slice(0, 45)
        yield markdownFixture.slice(45)
      }
      await thread.post(stream())
    })
    await webhook({ update_id: 2, activation_reason: "mention", message: message() })
    expect(calls.at(-1)?.body.text).toBe(markdownFixture)
    for (const call of calls.filter((call) => call.method === "sendMessage" || call.method === "editMessageText")) {
      expect(call.body.parse_markdown).toBe(true)
    }
  })

  test("retains API rate-limit retry timing", async () => {
    const adapter = createInlineAdapter({
      token: "x",
      webhookSecret: "y",
      fetch: (async () =>
        Response.json({
          ok: false,
          error_code: 429,
          description: "slow down",
          parameters: { retry_after: 3 },
        })) as typeof fetch,
    })
    try {
      await adapter.startTyping("inline:chat:10")
      throw new Error("Expected failure")
    } catch (error) {
      expect(error).toBeInstanceOf(RateLimitError)
      expect((error as RateLimitError).retryAfterMs).toBe(3000)
    }
  })
})
