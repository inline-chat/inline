import {
  DbObjectKind,
  messageKey,
  type Db,
} from "@inline/client/core"
import type { ChatID, MessageID } from "@inline/ids"

/**
 * Resolve once the sole account owner has committed and projected the local
 * optimistic message. A network result is deliberately not acceptance: an
 * offline send remains valid once its replay-safe outbox row is durable.
 */
export const waitForMessageSendAcceptance = (
  db: Db,
  chatId: ChatID,
  temporaryMessageId: MessageID,
  result: Promise<unknown>,
) => {
  const ref = db.ref(
    DbObjectKind.Message,
    messageKey(chatId, temporaryMessageId),
  )
  if (db.get(ref)) return Promise.resolve()

  return new Promise<void>((resolve, reject) => {
    let settled = false
    const finish = (operation: () => void) => {
      if (settled) return
      settled = true
      subscription.unsubscribe()
      operation()
    }
    const inspect = () => {
      if (db.get(ref)) finish(resolve)
    }
    const subscription = db.subscribeToObject(ref, inspect)
    inspect()
    void result.catch((error: unknown) => {
      if (db.get(ref)) {
        finish(resolve)
      } else {
        finish(() => reject(error))
      }
    })
  })
}
