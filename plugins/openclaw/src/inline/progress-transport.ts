import { Method, MessageSendMode, type InlineSdkClient, type Update } from "@inline-chat/realtime-sdk"
import type { ProgressTransport } from "../vendor/agent-activity/index.js"
import { buildChatPeer } from "./monitor-shared.js"

function randomInlineMessageId(): bigint {
  const bytes = new Uint8Array(8)
  globalThis.crypto.getRandomValues(bytes)
  const value = new DataView(bytes.buffer).getBigInt64(0, true)
  return value === 0n ? 1n : value
}

function firstSentMessageId(updates: readonly Update[]): bigint | null {
  for (const { update } of updates) {
    if (update.oneofKind === "newMessage" && update.newMessage.message) return update.newMessage.message.id
    if (update.oneofKind === "updateMessageId") return update.updateMessageId.messageId
  }
  return null
}

/**
 * Sends and edits Detailed progress messages in one chat as bot block
 * content: silent, without Markdown parsing (the server rejects block content
 * with it), and with the text as the fallback for older apps.
 */
export function createInlineProgressTransport(params: {
  client: Pick<InlineSdkClient, "invokeRaw">
  chatId: bigint
  onSent: (messageId: bigint) => void
}): ProgressTransport {
  const peerId = buildChatPeer(params.chatId)
  return {
    async send(doc) {
      const result = await params.client.invokeRaw(Method.SEND_MESSAGE, {
        oneofKind: "sendMessage",
        sendMessage: {
          peerId,
          // Lets the SDK replay the send across a reconnect without a duplicate.
          randomId: randomInlineMessageId(),
          message: doc.text,
          blockContent: doc.blockContent,
          sendMode: MessageSendMode.MODE_SILENT,
        },
      })
      if (result.oneofKind !== "sendMessage") {
        throw new Error(`inline progress: expected sendMessage result, got ${String(result.oneofKind)}`)
      }
      const messageId = firstSentMessageId(result.sendMessage.updates)
      if (messageId == null) throw new Error("inline progress: sendMessage returned no messageId")
      params.onSent(messageId)
      return messageId
    },
    async edit(messageId, doc) {
      // An edit replaces the whole message, so one retry is safe. After a
      // second failure the presenter stops editing this message.
      for (let attempt = 0; ; attempt++) {
        try {
          const result = await params.client.invokeRaw(Method.EDIT_MESSAGE, {
            oneofKind: "editMessage",
            editMessage: { messageId, peerId, text: doc.text, blockContent: doc.blockContent },
          })
          if (result.oneofKind !== "editMessage") {
            throw new Error(`inline progress: expected editMessage result, got ${String(result.oneofKind)}`)
          }
          return
        } catch (error) {
          if (attempt >= 1) throw error
        }
      }
    },
  }
}
