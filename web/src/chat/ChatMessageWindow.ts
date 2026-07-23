import {
  GetChatHistoryMode,
  getChatHistory,
  type Db,
  type RealtimeService,
} from "@inline/client"
import type { ChatID, MessageID } from "@inline/ids"
import { inputPeer, type InlinePeerRoute } from "../inline/data/peer"

export const chatAroundWindow = {
  beforeLimit: 30,
  afterLimit: 29,
} as const

/** Native-shaped jump preparation: try the bounded local `(date,messageId)`
 * index first, ask the protocol for one around window on a miss, then compact
 * the renderer projection through the same local window operation. */
export async function loadChatWindowAroundMessage({
  db,
  realtime,
  peer,
  chatId,
  targetMessageId,
}: {
  db: Db
  realtime: RealtimeService
  peer: InlinePeerRoute
  chatId: ChatID
  targetMessageId: MessageID
}) {
  const window = {
    messageId: targetMessageId,
    ...chatAroundWindow,
  }
  if (await db.loadLocalWindowAroundMessage(chatId, window)) {
    return true
  }

  const result = await realtime.query(
    getChatHistory({
      peerId: inputPeer(peer),
      mode: GetChatHistoryMode.HISTORY_MODE_AROUND,
      anchorId: targetMessageId,
      beforeLimit: chatAroundWindow.beforeLimit,
      afterLimit: chatAroundWindow.afterLimit,
      includeAnchor: true,
    }),
  )
  if (result?.oneofKind !== "getChatHistory") return false
  const responseContainsTarget = result.getChatHistory.messages.some(
    (message) => message.id.toString() === targetMessageId,
  )
  const compacted = await db.loadLocalWindowAroundMessage(chatId, window)
  return compacted || responseContainsTarget
}
