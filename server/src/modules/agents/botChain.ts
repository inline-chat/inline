import { db } from "@in/server/db"
import { messages, users } from "@in/server/db/schema"
import { and, desc, eq, isNull } from "drizzle-orm"

/**
 * The one loop backstop for bots talking to bots: after this many bot messages
 * in a row in one chat, with no person writing, bots stop waking there until a
 * person writes. Generous on purpose; hand-backs that don't quote the asker are
 * what keep normal exchanges short.
 */
export const BOT_CHAIN_LIMIT = 50

/** True when the chat's latest `limit` non-system messages all come from bots. */
export async function botChainExhausted(chatId: number, limit = BOT_CHAIN_LIMIT): Promise<boolean> {
  const rows = await db
    .select({ bot: users.bot })
    .from(messages)
    .innerJoin(users, eq(users.id, messages.fromId))
    .where(and(eq(messages.chatId, chatId), isNull(messages.systemMessageEncrypted)))
    .orderBy(desc(messages.messageId))
    .limit(limit)
  return rows.length >= limit && rows.every((row) => row.bot === true)
}
