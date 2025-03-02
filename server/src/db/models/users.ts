// Note:Mostly AI generated

import { eq, inArray, and, not, sql } from "drizzle-orm"
import { db } from "@in/server/db"
import { dialogs, users, files, type DbUser, type DbFile } from "@in/server/db/schema"

export class UsersModel {
  static async getUserById(id: number): Promise<DbUser | undefined> {
    const user = await db.query.users.findFirst({
      where: eq(users.id, id),
    })

    return user
  }

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

  static async getUserWithPhoto(userId: number) {
    const user = await db.query.users.findFirst({
      where: eq(users.id, userId),
      with: {
        photo: true,
      },
    })

    if (!user) {
      throw new Error("User not found")
    }

    return user
  }

  static async getUsersWithPhotos(userIds: number[]): Promise<Array<{ user: DbUser; photoFile?: DbFile | undefined }>> {
    const usersWithPhotos = await db.query.users.findMany({
      where: inArray(users.id, userIds),
      with: {
        photo: true,
      },
    })

    return usersWithPhotos.map((user) => ({
      user,
      photoFile: user.photo ?? undefined,
    }))
  }

  static async searchUsers({
    query,
    limit,
    excludeUserId,
  }: {
    query: string
    limit: number
    excludeUserId?: number
  }): Promise<Array<{ user: DbUser; photoFile?: DbFile | undefined }>> {
    const usersWithPhotos = await db.query.users.findMany({
      where: and(
        sql`${users.username} ilike ${"%" + query + "%"}`,
        excludeUserId ? not(eq(users.id, excludeUserId)) : undefined,
      ),
      limit,
      with: {
        photo: true,
      },
    })

    return usersWithPhotos.map((user) => ({
      user,
      photoFile: user.photo ?? undefined,
    }))
  }
}
