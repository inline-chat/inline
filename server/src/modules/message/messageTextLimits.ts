import {
  MAX_MESSAGE_ENTITIES_BYTES,
  MAX_MESSAGE_TEXT_UTF16_UNITS,
  MAX_MESSAGE_TEXT_UTF8_BYTES,
} from "@in/server/modules/encryption/limits"
import { RealtimeRpcError } from "@in/server/realtime/errors"

export const messageTextLimits = {
  utf16Units: MAX_MESSAGE_TEXT_UTF16_UNITS,
  utf8Bytes: MAX_MESSAGE_TEXT_UTF8_BYTES,
  entityBytes: MAX_MESSAGE_ENTITIES_BYTES,
} as const

/** Reject hostile input before Markdown creates source maps or an AST. The
 * encryption layer repeats both checks as a final persistence boundary. */
export function validateOutgoingMessageText(text: string): void {
  if (text.length > messageTextLimits.utf16Units) throw RealtimeRpcError.BadRequest()
  if (Buffer.byteLength(text, "utf8") > messageTextLimits.utf8Bytes) throw RealtimeRpcError.BadRequest()
}
