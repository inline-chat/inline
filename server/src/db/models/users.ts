// Note:Mostly AI generated

import { eq, inArray, and, not, sql } from "drizzle-orm"
import { db } from "@in/server/db"
import { users, userNotDeleted, type DbUser, type DbFile, type DbUserWithProfile } from "@in/server/db/schema"
import parsePhoneNumber from "libphonenumber-js"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { isValidEmail } from "@in/server/utils/validate"
import { Log } from "@in/server/utils/log"

const log = new Log("UsersModel")

export class UsersModel {
  static isDeleted(user: Pick<DbUser, "deleted"> | undefined | null): boolean {
    return user?.deleted === true
  }

  static async getActiveUserIds(userIds: number[]): Promise<number[]> {
    const uniqueUserIds = [...new Set(userIds.filter((id) => Number.isSafeInteger(id) && id > 0))]
    if (uniqueUserIds.length === 0) {
      return []
    }

    const rows = await db
      .select({ id: users.id })
      .from(users)
      .where(and(inArray(users.id, uniqueUserIds), userNotDeleted()))

    const activeUserIds = new Set(rows.map((row) => row.id))
    return uniqueUserIds.filter((id) => activeUserIds.has(id))
  }

  static async getActiveUserById(id: number): Promise<DbUser | undefined> {
    const user = await db._query.users.findFirst({
      where: and(eq(users.id, id), userNotDeleted()),
    })

    return user
  }

  /**
   * Get a user by id
   *
   * @param id - The id of the user
   * @returns The user
   */
  static async getUserById(id: number): Promise<DbUser | undefined> {
    const user = await db._query.users.findFirst({
      where: eq(users.id, id),
    })

    return user
  }

  static async getUserWithProfile(id: number): Promise<DbUserWithProfile | undefined> {
    let user = await db.query.users.findFirst({
      where: { id },
      with: {
        photoFile: true,
      },
    })

    return user
  }

  /**
   * Get a user by email
   *
   * @param email - The email of the user
   * @returns The user
   */
  static async getUserByEmail(email: string): Promise<DbUser | undefined> {
    const user = await db._query.users.findFirst({
      where: eq(users.email, email),
    })

    return user
  }

  /**
   * Get a user by phone number
   *
   * @param phoneNumber - The phone number of the user
   * @returns The user
   */
  static async getUserByPhoneNumber(phoneNumber: string): Promise<DbUser | undefined> {
    const e164PhoneNumber = UsersModel.normalizePhoneNumber(phoneNumber)

    const user = await db._query.users.findFirst({
      where: eq(users.phoneNumber, e164PhoneNumber),
    })

    return user
  }

  static normalizePhoneNumber(phoneNumber: string): string {
    const parsedPhoneNumber = parsePhoneNumber(phoneNumber)
    if (!parsedPhoneNumber?.isValid()) {
      throw RealtimeRpcError.PhoneNumberInvalid()
    }

    return parsedPhoneNumber.number
  }

  /**
   * Create a user when invited to a space
   *
   * @param input - Either email or phone number
   * @returns The created user
   */
  static async createUserWhenInvited(input: { email: string } | { phoneNumber: string }): Promise<DbUser> {
    let email: string | undefined
    let phoneNumber: string | undefined

    if ("email" in input) {
      // Validate email
      if (!isValidEmail(input.email)) {
        throw RealtimeRpcError.EmailInvalid()
      }

      email = input.email
    }

    if ("phoneNumber" in input) {
      phoneNumber = UsersModel.normalizePhoneNumber(input.phoneNumber)
    }

    const [created] = await db
      .insert(users)
      .values({
        email,
        phoneNumber,
        pendingSetup: true,

        phoneVerified: false,
        emailVerified: false,
        firstName: null,
        lastName: null,
        username: null,
      })
      .onConflictDoNothing()
      .returning()

    if (created) {
      return created
    }

    const existing = email
      ? await UsersModel.getUserByEmail(email)
      : phoneNumber
        ? await UsersModel.getUserByPhoneNumber(phoneNumber)
        : undefined

    if (UsersModel.isDeleted(existing)) {
      throw RealtimeRpcError.UserIdInvalid()
    }
    if (!existing) {
      log.error("Failed to resolve user after invited-user conflict", { hasEmail: email !== undefined })
      throw RealtimeRpcError.InternalError()
    }

    return existing
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
    const user = await db._query.users.findFirst({
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
    const usersWithPhotos = await db._query.users.findMany({
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
    includeBotCreatorId,
  }: {
    query: string
    limit: number
    excludeUserId?: number
    includeBotCreatorId?: number
  }): Promise<Array<{ user: DbUser; photoFile?: DbFile | undefined }>> {
    const normalizedQuery = query.trim()
    if (normalizedQuery.length === 0) {
      return []
    }

    const exactUsername = normalizedQuery.toLowerCase()
    const queryMatch = includeBotCreatorId
      ? sql`(
          strpos(lower(${users.username}), ${exactUsername}) > 0
          or (
            ${users.bot} is true
            and ${users.botCreatorId} = ${includeBotCreatorId}
            and strpos(lower(concat_ws(' ', ${users.firstName}, ${users.lastName})), ${exactUsername}) > 0
          )
        )`
      : sql`strpos(lower(${users.username}), ${exactUsername}) > 0`
    const botVisibility = includeBotCreatorId
      ? sql`(
          ${users.bot} is not true
          or lower(${users.username}) = ${exactUsername}
          or ${users.botCreatorId} = ${includeBotCreatorId}
        )`
      : sql`(${users.bot} is not true or lower(${users.username}) = ${exactUsername})`
    const searchOrder = includeBotCreatorId
      ? sql`case
          when lower(${users.username}) = ${exactUsername} then 0
          when ${users.botCreatorId} = ${includeBotCreatorId} then 1
          else 2
        end`
      : users.id
    const usersWithPhotos = await db._query.users.findMany({
      where: and(
        queryMatch,
        botVisibility,
        excludeUserId ? not(eq(users.id, excludeUserId)) : undefined,
        eq(users.pendingSetup, false),
        userNotDeleted(),
      ),
      orderBy: [searchOrder, users.id],
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
