import { messages } from "@in/server/db/schema/messages"
import { eq, isNull, or } from "drizzle-orm"

/** Quiet generated service rows remain in history without becoming previews. */
export function messageActivityPredicate() {
  return or(eq(messages.countsAsUnread, true), isNull(messages.systemMessageEncrypted))
}
