// Copied into an isolated npm consumer: imports must resolve to candidate tarballs.
import assert from "node:assert/strict"
import { writeFile } from "node:fs/promises"
import { InlineBotClient } from "@inline-chat/bot-client"
import { InlineSdkClient } from "@inline-chat/realtime-sdk"
import { InlineAdapter } from "@inline-chat/chat-sdk"
import { Chat } from "chat"
import { createMemoryState } from "@chat-adapter/state-memory"

const baseUrl = process.env.INLINE_E2E_BASE_URL
const humanId = Number(process.env.INLINE_E2E_HUMAN_ID)
const botId = Number(process.env.INLINE_E2E_BOT_ID)
const bot = new InlineBotClient({ token: process.env.INLINE_E2E_TOKEN, baseUrl })
const receipts = []
let chatId
const record = (scenario) => receipts.push({ scenario, status: "passed" })
const waitFor = async (read, label) => {
  const deadline = Date.now() + 15_000
  while (Date.now() < deadline) {
    const value = await read()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 20))
  }
  throw new Error(`${label} timed out`)
}
let receiver, human, chat
try {
  const me = await bot.getMe()
  assert.equal(me.ok, true)
  assert.equal(me.result.user.is_bot, true)
  assert.equal(me.result.user.id, botId)
  const conversation = await bot.getChat({ user_id: humanId })
  assert.equal(conversation.ok, true)
  chatId = conversation.result.chat.chat_id
  const sent = await bot.sendMessage({ user_id: humanId, text: "ci-packed-bot-round-trip" })
  assert.equal(sent.ok, true)
  const history = await bot.getMessages({ chat_id: chatId, message_ids: [sent.result.message.message_id] })
  assert.equal(history.ok, true)
  assert.equal(history.result.messages[0].text, "ci-packed-bot-round-trip")
  record("bot-http-message-body")

  const received = []
  receiver = new InlineSdkClient({ token: process.env.INLINE_E2E_TOKEN, baseUrl })
  const consume = (async () => { for await (const event of receiver.events()) received.push(event) })()
  await receiver.connect()
  assert.equal((await receiver.getMe()).userId, BigInt(botId))
  human = new InlineSdkClient({ token: process.env.INLINE_E2E_HUMAN_TOKEN, baseUrl })
  const humanReceived = []
  const humanConsumer = (async () => { for await (const event of human.events()) humanReceived.push(event) })()
  await human.connect()
  const input = { userId: botId, text: "ci-packed-sdk-inbound", randomId: 734901n }
  const inbound = await human.sendMessage(input)
  assert.ok(inbound.messageId)
  const delivered = await waitFor(() => received.find((event) => event.kind === "message.new" && event.message.id === inbound.messageId), "SDK recipient message")
  assert.equal(delivered.message.message, input.text)
  record("sdk-recipient-websocket-message")
  const repeated = await human.sendMessage(input)
  assert.equal(repeated.messageId, inbound.messageId, "same idempotency key must return the persisted message")
  const stored = await receiver.getMessages({ userId: humanId, messageIds: [inbound.messageId] })
  assert.equal(stored.messages.length, 1)
  assert.equal(stored.messages[0].message, input.text)
  record("sdk-idempotent-send")
  await receiver.close()
  await consume
  receiver = new InlineSdkClient({ token: process.env.INLINE_E2E_TOKEN, baseUrl })
  await receiver.connect()
  assert.equal((await receiver.getMessages({ userId: humanId, messageIds: [inbound.messageId] })).messages[0].message, input.text)
  record("sdk-new-connection-persisted-history")

  const adapter = new InlineAdapter({ token: process.env.INLINE_E2E_TOKEN, webhookSecret: "ci-secret", baseUrl })
  chat = new Chat({ userName: "ci-bot", adapters: { inline: adapter }, state: createMemoryState(), logger: "silent" })
  let dispatches = 0
  chat.onDirectMessage(async (thread, message) => {
    if (message.text !== "ci-chat-sdk-inbound") return
    dispatches++
    await thread.post("ci-chat-sdk-persisted-reply")
  })
  await chat.initialize()
  const trigger = await human.sendMessage({ userId: botId, text: "ci-chat-sdk-inbound" })
  const update = await waitFor(async () => {
    const updates = await bot.getUpdates({ timeout: 0, limit: 100 })
    assert.equal(updates.ok, true)
    return updates.result.find((item) => item.message?.message_id === Number(trigger.messageId) && item.message?.text === "ci-chat-sdk-inbound")
  }, "real Bot API update")
  const webhook = (secret) => new Request("http://localhost/inline", { method: "POST", headers: {
    "content-type": "application/json", "x-inline-bot-api-secret-token": secret,
  }, body: JSON.stringify(update) })
  assert.equal((await adapter.handleWebhook(webhook("wrong-secret"))).status, 401)
  assert.equal(dispatches, 0)
  assert.equal((await adapter.handleWebhook(webhook("ci-secret"))).status, 200)
  assert.equal((await adapter.handleWebhook(webhook("ci-secret"))).status, 200)
  assert.equal(dispatches, 1, "retrying the same webhook must not run the host handler twice")
  const reply = await waitFor(() => humanReceived.find((event) => event.kind === "message.new" && event.message.message === "ci-chat-sdk-persisted-reply"), "Chat SDK reply")
  const replyHistory = await human.getMessages({ userId: botId, messageIds: [reply.message.id] })
  assert.equal(replyHistory.messages[0].message, "ci-chat-sdk-persisted-reply")
  record("chat-sdk-real-update-handler-and-reply")
  record("chat-sdk-webhook-secret-and-duplicate-delivery")
  await human.close()
  await humanConsumer
} finally {
  await chat?.shutdown()
  await receiver?.close()
  await human?.close()
  await writeFile(process.env.INLINE_E2E_RECEIPT, JSON.stringify({ sourceSha: process.env.INLINE_E2E_SOURCE_SHA, chatId, scenarios: receipts }, null, 2) + "\n")
}
