import { db } from "@in/server/db"
import { botTokens } from "@in/server/db/schema/botTokens"
import { decrypt, encrypt } from "@in/server/modules/encryption/encryption"
import { Log } from "@in/server/utils/log"
import { eq } from "drizzle-orm"

const log = new Log("BotTokensModel")

export const BotTokensModel = {
  async create({ botUserId, sessionId, token }: { botUserId: number; sessionId: number; token: string }) {
    const encrypted = encrypt(token)

    const [row] = await db
      .insert(botTokens)
      .values({
        botUserId,
        sessionId,
        tokenEncrypted: encrypted.encrypted,
        tokenIv: encrypted.iv,
        tokenTag: encrypted.authTag,
      })
      .returning()

    if (!row) {
      throw new Error("Failed to create bot token")
    }

    return row
  },

  async upsert({ botUserId, sessionId, token }: { botUserId: number; sessionId: number; token: string }) {
    const encrypted = encrypt(token)

    const [row] = await db
      .insert(botTokens)
      .values({
        botUserId,
        sessionId,
        tokenEncrypted: encrypted.encrypted,
        tokenIv: encrypted.iv,
        tokenTag: encrypted.authTag,
        date: new Date(),
      })
      .onConflictDoUpdate({
        target: [botTokens.botUserId],
        set: {
          sessionId,
          tokenEncrypted: encrypted.encrypted,
          tokenIv: encrypted.iv,
          tokenTag: encrypted.authTag,
          date: new Date(),
        },
      })
      .returning()

    if (!row) {
      throw new Error("Failed to upsert bot token")
    }

    return row
  },

  async getTokenByBotUserId(botUserId: number): Promise<string | null> {
    const [row] = await db.select().from(botTokens).where(eq(botTokens.botUserId, botUserId)).limit(1)

    if (!row) {
      return null
    }

    try {
      return decrypt({
        encrypted: row.tokenEncrypted,
        iv: row.tokenIv,
        authTag: row.tokenTag,
      })
    } catch (error) {
      log.error("Failed to decrypt bot token", { botUserId, error })
      return null
    }
  },
}
