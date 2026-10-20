import { createFloodGuardedLog } from "@in/server/utils/floodGuardedLog"
import { Log } from "@in/server/utils/log"

/** How far a client send date may trail server receipt and still date the message. */
export const CLIENT_SEND_DATE_MAX_PAST_MS = 2 * 60 * 1000
/** How far a client send date may lead server receipt and still date the message. */
export const CLIENT_SEND_DATE_MAX_FUTURE_MS = 2 * 60 * 1000

export type ResolvedMessageDate = {
  date: Date
  /** The client sent a date that was not usable, so receipt time was used instead. */
  replaced: boolean
}

/**
 * Clients date their own messages so optimistic ordering and caches stay put.
 * A client send date (unix seconds) outside the window around server receipt,
 * or not a usable number, is replaced with receipt time.
 */
export const resolveMessageDate = (sendDate: number | undefined, now = Date.now()): ResolvedMessageDate => {
  if (sendDate === undefined) return { date: new Date(now), replaced: false }
  const sendDateMs = sendDate * 1000
  const accepted =
    sendDateMs >= now - CLIENT_SEND_DATE_MAX_PAST_MS && sendDateMs <= now + CLIENT_SEND_DATE_MAX_FUTURE_MS
  return accepted ? { date: new Date(sendDateMs), replaced: false } : { date: new Date(now), replaced: true }
}

export type ReplacedSendDate = {
  userId: number
  chatId: number
  sendDate: number
  receivedAt: number
  clientType?: string
  layer?: number
}

const log = new Log("message.clientSendDate")
const writeReplaced = createFloodGuardedLog({
  write: (message, fields) => log.info(message, fields),
  summary: "suppressed replaced client send date logs",
})

/** Each replaced date is an anomaly worth a line; the shared flood guard caps bursts. */
export const logReplacedSendDate = (replaced: ReplacedSendDate) => {
  const driftMs = replaced.sendDate * 1000 - replaced.receivedAt
  writeReplaced(
    "replaced client send date outside the drift window",
    {
      userId: replaced.userId,
      chatId: replaced.chatId,
      driftSeconds: Number.isFinite(driftMs) ? Math.round(driftMs / 1000) : null,
      clientType: replaced.clientType,
      layer: replaced.layer,
    },
    replaced.receivedAt,
  )
}
