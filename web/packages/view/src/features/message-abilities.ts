/**
 * What the viewer can do with one message, from its row alone (Mac
 * `MessageView.createMessageMenu`). The server has the last word: a delete
 * of someone else's message may still be refused (`server`), which the
 * action's notice says.
 */

import type { MessageRow } from "@inline/core-protocol"
import type { UserID } from "@inline/ids"

export type MessageAbilities = {
  /** A message the server has (not sending or failed). Mac `regularMessage`. */
  readonly regular: boolean
  readonly reply: boolean
  /** The viewer's own sent message, not a service message or a send with an upload. */
  readonly edit: boolean
  /** Anything not still sending: by message ID, or by client key for a failed send. */
  readonly delete: boolean
  /** A send from this device still sending: deleting it cancels the send. */
  readonly cancel: boolean
  readonly react: boolean
  /** A failed send from this device. */
  readonly resend: boolean
  readonly copyText: boolean
  readonly copyLink: boolean
}

export const isOwnMessage = (row: MessageRow, viewerId: UserID): boolean => row.out || row.fromId === viewerId

export const messageAbilities = (row: MessageRow, viewerId: UserID): MessageAbilities => {
  const hasId = row.messageId !== undefined
  const regular = hasId && row.state !== "sending" && row.state !== "failed"
  const sending = row.state === "sending"
  return {
    regular,
    reply: regular,
    edit: canEditMessage(row, viewerId),
    delete: canDeleteMessage(row),
    cancel: sending && row.clientKey !== undefined,
    react: regular && row.service === undefined,
    resend: row.state === "failed" && row.clientKey !== undefined,
    copyText: row.text.trim().length > 0,
    copyLink: regular,
  }
}

/** Whether the viewer can edit this message: their own, sent, with a server ID, not a service message or an upload. */
export const canEditMessage = (row: MessageRow, viewerId: UserID): boolean =>
  isOwnMessage(row, viewerId) &&
  row.state === "sent" &&
  row.messageId !== undefined &&
  row.service === undefined &&
  row.upload === undefined

/**
 * Whether the viewer can ask to delete this message: anything not still
 * sending (that is a cancel) that the core can name, by server ID or, for a
 * send from this device, by client key. Others' messages are offered as on
 * the Mac; the server refuses what the viewer may not delete.
 */
export const canDeleteMessage = (row: MessageRow): boolean =>
  row.state !== "sending" && (row.messageId !== undefined || row.clientKey !== undefined)
