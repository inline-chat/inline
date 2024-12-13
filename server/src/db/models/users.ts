// Note:Mostly AI generated

import { eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { dialogs, users } from "@in/server/db/schema"

export class UsersModel {
  // Update user's online status
  static async setOnline(id: number, online: boolean): Promise<{ online: boolean; lastOnline: Date | null }> {
    if (!id || id <= 0) {
      throw new Error("Invalid user ID")
    }

    try {
      let previousUser = await db.select().from(users).where(eq(users.id, id)).limit(1)

      if (!previousUser[0]) {
        throw new Error(`User not found: ${id}`)
      }

      let previousOnline = previousUser[0].online

      const result = await db
        .update(users)
        .set({
          online,
          // Only update lastOnline if the user is being set offline and has previously not been online to avoid jumps in the lastOnline timestamp
          ...(online === false && previousOnline === true ? { lastOnline: new Date() } : {}),
        })
        .where(eq(users.id, id))
        .returning({ online: users.online, lastOnline: users.lastOnline })

      if (!result.length) {
        throw new Error(`User not found: ${id}`)
      }
      if (!result[0]) {
        throw new Error(`Failed to update user online status: ${id}`)
      }

      return {
        online: result[0].online,
        lastOnline: result[0].lastOnline,
      }
    } catch (error) {
      throw new Error(
        `Failed to update user online status: ${error instanceof Error ? error.message : "Unknown error"}`,
      )
    }
  }
}
