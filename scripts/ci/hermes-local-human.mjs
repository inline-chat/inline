// Runs from the clean consumer; all RPCs use its packed SDK/protocol artifacts.
import assert from "node:assert/strict"
import { createHash, randomBytes } from "node:crypto"
import { Method } from "@inline-chat/protocol"
import { InlineSdkClient } from "@inline-chat/realtime-sdk"

const local = new URL(process.env.INLINE_E2E_BASE_URL)
assert.ok(["127.0.0.1", "localhost", "[::1]"].includes(local.hostname), "Only the owned local test server is allowed")
const chunks = []
for await (const chunk of process.stdin) chunks.push(chunk)
const operation = JSON.parse(Buffer.concat(chunks).toString("utf8"))
const id = (value) => {
  assert.match(String(value), /^[1-9]\d*$/, "A persisted positive physical ID is required")
  return BigInt(value)
}
const peer = (chatId) => ({ type: { oneofKind: "chat", chat: { chatId: id(chatId) } } })
const target = operation.chatId
  ? { chatId: id(operation.chatId) }
  : { userId: id(operation.botId ?? process.env.INLINE_E2E_BOT_ID) }
const client = new InlineSdkClient({
  token: process.env.INLINE_E2E_HUMAN_TOKEN,
  baseUrl: local.toString(),
})

try {
  await client.connect()
  assert.equal((await client.getMe()).userId, id(process.env.INLINE_E2E_HUMAN_ID))
  let result
  switch (operation.kind) {
    case "send": {
      const peerId = operation.chatId ? peer(operation.chatId)
        : { type: { oneofKind: "user", user: { userId: target.userId } } }
      if (!operation.chatId) {
        // GET_CHAT establishes the real DM/dialog before the raw send RPC.
        const opened = await client.invoke(Method.GET_CHAT, { oneofKind: "getChat", getChat: { peerId } })
        assert.ok(opened.getChat.chat?.id, "The human/bot DM was not established")
      }
      const sent = await client.invoke(Method.SEND_MESSAGE, { oneofKind: "sendMessage", sendMessage: {
        peerId, message: operation.text,
        randomId: (randomBytes(8).readBigUInt64BE() & ((1n << 63n) - 1n)) || 1n,
      } })
      const updates = sent.sendMessage.updates.filter((update) => update.update.oneofKind === "newMessage")
      assert.equal(updates.length, 1, "Human input needs its actual committed update")
      const messageId = updates[0].update.newMessage.message?.id
      assert.ok(messageId, "Human input was not persisted")
      assert.ok(Number.isSafeInteger(updates[0].seq) && updates[0].seq > 0, "Committed chat sequence is missing")
      const { messages } = await client.getMessages({ ...target, messageIds: [messageId] })
      assert.equal(messages.length, 1)
      assert.equal(messages[0].message, operation.text)
      result = { messageId: String(messageId), chatId: String(messages[0].chatId), seq: updates[0].seq,
        textSha256: createHash("sha256").update(messages[0].message).digest("hex") }
      break
    }
    case "edit": {
      await client.invoke(Method.EDIT_MESSAGE, { oneofKind: "editMessage", editMessage: {
        messageId: id(operation.messageId), peerId: peer(operation.chatId), text: operation.text,
      } })
      const { messages } = await client.getMessages({ chatId: id(operation.chatId), messageIds: [id(operation.messageId)] })
      assert.equal(messages.length, 1)
      assert.equal(messages[0].message, operation.text, "Current server source did not change")
      result = { messageId: String(messages[0].id), chatId: String(messages[0].chatId), edited: true }
      break
    }
    case "delete": {
      await client.invoke(Method.DELETE_MESSAGES, { oneofKind: "deleteMessages", deleteMessages: {
        messageIds: [id(operation.messageId)], peerId: peer(operation.chatId),
      } })
      const { messages } = await client.getMessages({ chatId: id(operation.chatId), messageIds: [id(operation.messageId)] })
      assert.equal(messages.length, 0, "Deleted physical source is still readable")
      result = { messageId: String(operation.messageId), chatId: String(operation.chatId), deleted: true }
      break
    }
    case "create-private-chat": {
      const participantIds = [process.env.INLINE_E2E_HUMAN_ID, operation.botId]
      if (operation.otherBotId) participantIds.push(operation.otherBotId)
      assert.equal(new Set(participantIds.map(String)).size, participantIds.length)
      const created = await client.invoke(Method.CREATE_CHAT, { oneofKind: "createChat", createChat: {
        title: "Hermes local access qualification", isPublic: false,
        participants: participantIds.map((userId) => ({ userId: id(userId) })),
      } })
      assert.ok(created.createChat.chat)
      assert.equal(created.createChat.chat.isPublic, false)
      result = { chatId: String(created.createChat.chat.id) }
      break
    }
    case "revoke-bot": {
      await client.invoke(Method.REMOVE_CHAT_PARTICIPANT, { oneofKind: "removeChatParticipant", removeChatParticipant: {
        chatId: id(operation.chatId), userId: id(operation.botId),
      } })
      const participants = await client.invoke(Method.GET_CHAT_PARTICIPANTS, {
        oneofKind: "getChatParticipants", getChatParticipants: { chatId: id(operation.chatId) },
      })
      assert.ok(participants.getChatParticipants.participants.every((p) => String(p.userId) !== String(operation.botId)),
        "The bot still has its participant grant")
      result = { chatId: String(operation.chatId), botId: String(operation.botId), accessRevoked: true }
      break
    }
    default:
      throw new Error("Unknown local Hermes human operation")
  }
  console.log(`HERMES_HUMAN_RESULT=${JSON.stringify(result)}`)
} catch (error) {
  // RPC diagnostics can include credentials. The Python report records only the
  // operation and physical IDs; never print request/exception bodies here.
  console.error(`Local Hermes human operation failed: ${error?.name ?? "Error"}`)
  process.exitCode = 1
} finally {
  await client.close()
}
