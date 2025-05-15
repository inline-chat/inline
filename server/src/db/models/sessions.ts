// Note:Mostly AI generated

import { and, eq, inArray, isNull } from "drizzle-orm"
import { sessions, type DbSession, type DbNewSession } from "@in/server/db/schema/sessions"
import { encrypt, decrypt, type EncryptedData } from "@in/server/modules/encryption/encryption"
import { db } from "@in/server/db"

// Define interfaces for the personal data structure
export interface SessionPersonalData {
  country?: string | undefined
  region?: string | undefined
  city?: string | undefined
  timezone?: string | undefined
  ip?: string | undefined
  deviceName?: string | undefined
}

// Interface for creating a new session
export interface CreateSessionData {
  userId: number
  tokenHash: string
  personalData: SessionPersonalData
  applePushToken?: string
  clientType: "ios" | "macos" | "web"
  clientVersion?: string | undefined
  osVersion?: string | undefined
  deviceId?: string | undefined
}

// Interface for session with decrypted data
export interface SessionWithDecryptedData
  extends Omit<
    DbSession,
    | "personalDataEncrypted"
    | "personalDataIv"
    | "personalDataTag"
    | "applePushTokenEncrypted"
    | "applePushTokenIv"
    | "applePushTokenTag"
  > {
  personalData: SessionPersonalData
  applePushToken: string | null
}

export class SessionsModel {
  // Create a new session
  static async create(data: CreateSessionData): Promise<SessionWithDecryptedData> {
    if (!data.userId || !data.tokenHash) {
      throw new Error("Missing required fields: userId and tokenHash are required")
    }

    const now = new Date()

    try {
      // Encrypt personal data
      const personalData = JSON.stringify(data.personalData)
      const encryptedPersonalData = encrypt(personalData)

      // Encrypt push token if present
      let applePushTokenData: EncryptedData | null = null
      if (data.applePushToken) {
        applePushTokenData = encrypt(data.applePushToken)
      }

      const sessionData: DbNewSession = {
        userId: data.userId,
        tokenHash: data.tokenHash,
        lastActive: now,
        date: now,
        deviceId: data.deviceId ?? null,

        // Store encrypted personal data
        personalDataEncrypted: encryptedPersonalData.encrypted,
        personalDataIv: encryptedPersonalData.iv,
        personalDataTag: encryptedPersonalData.authTag,

        // Store encrypted push token if present
        ...(applePushTokenData && {
          applePushTokenEncrypted: applePushTokenData.encrypted,
          applePushTokenIv: applePushTokenData.iv,
          applePushTokenTag: applePushTokenData.authTag,
        }),

        // Client info
        clientType: data.clientType,
        clientVersion: data.clientVersion ?? null,
        osVersion: data.osVersion ?? null,
      }

      // check if a previous userId session deviceId exists, delete that session
      if (data.deviceId) {
        let hasExistingDevice = await db
          .select()
          .from(sessions)
          .where(and(eq(sessions.deviceId, data.deviceId), eq(sessions.userId, data.userId)))
        let existingDevice = hasExistingDevice[0]
        if (existingDevice) {
          await db.delete(sessions).where(eq(sessions.id, existingDevice.id))
          console.info(`Deleted previous session with deviceId: ${data.deviceId}`)
        }
      }

      const [session] = await db.insert(sessions).values(sessionData).returning()

      if (!session) {
        throw new Error("Failed to create session")
      }

      return this.decryptSessionData(session)
    } catch (error) {
      throw new Error(`Failed to create session: ${error instanceof Error ? error.message : "Unknown error"}`)
    }
  }

  // Get session by ID with decrypted data
  static async getById(id: number): Promise<SessionWithDecryptedData> {
    if (!id || id <= 0) {
      throw new Error("Invalid session ID")
    }

    const session = await db._query.sessions.findFirst({
      where: eq(sessions.id, id),
    })

    if (!session) {
      throw new Error(`Session not found: ${id}`)
    }

    return this.decryptSessionData(session)
  }

  // Update session's last active timestamp
  static async setActive(id: number, active: boolean): Promise<void> {
    if (!id || id <= 0) {
      throw new Error("Invalid session ID")
    }

    try {
      const result = await db
        .update(sessions)
        .set({ active, lastActive: new Date() })
        .where(eq(sessions.id, id))
        .returning({ id: sessions.id })

      if (!result.length) {
        throw new Error(`Session not found: ${id}`)
      }
    } catch (error) {
      throw new Error(
        `Failed to update session last active: ${error instanceof Error ? error.message : "Unknown error"}`,
      )
    }
  }

  // Update session's last active timestamp
  static async setActiveBulk(ids: number[], active: boolean): Promise<void> {
    try {
      await db.update(sessions).set({ active, lastActive: new Date() }).where(inArray(sessions.id, ids))
    } catch (error) {
      throw new Error(
        `Failed to update sessions last active in bulk: ${error instanceof Error ? error.message : "Unknown error"}`,
      )
    }
  }

  static async updateApplePushToken(id: number, applePushToken: string, deviceId?: string): Promise<void> {
    const encryptedApplePushToken = encrypt(applePushToken)

    await db
      .update(sessions)
      .set({
        applePushToken: null,
        applePushTokenEncrypted: encryptedApplePushToken.encrypted,
        applePushTokenIv: encryptedApplePushToken.iv,
        applePushTokenTag: encryptedApplePushToken.authTag,
        deviceId: deviceId ?? null,
      })
      .where(eq(sessions.id, id))
  }

  // Revoke a session
  static async revoke(id: number): Promise<void> {
    if (!id || id <= 0) {
      throw new Error("Invalid session ID")
    }

    try {
      const result = await db
        .update(sessions)
        .set({ revoked: new Date() })
        .where(eq(sessions.id, id))
        .returning({ id: sessions.id })

      if (!result.length) {
        throw new Error(`Session not found: ${id}`)
      }
    } catch (error) {
      throw new Error(`Failed to revoke session: ${error instanceof Error ? error.message : "Unknown error"}`)
    }
  }

  // Helper method to decrypt all session data
  private static decryptSessionData(session: DbSession): SessionWithDecryptedData {
    let strippedSession = {
      ...session,
      personalDataEncrypted: undefined,
      personalDataIv: undefined,
      personalDataTag: undefined,
      applePushTokenEncrypted: undefined,
      applePushTokenIv: undefined,
      applePushTokenTag: undefined,
    }
    return {
      ...strippedSession,
      personalData: this.decryptPersonalData(session),
      applePushToken: this.decryptApplePushToken(session),
    }
  }

  // Helper method to decrypt personal data
  private static decryptPersonalData(session: DbSession): SessionPersonalData {
    try {
      if (!session.personalDataEncrypted || !session.personalDataIv || !session.personalDataTag) {
        return {}
      }

      const decrypted = decrypt({
        encrypted: session.personalDataEncrypted,
        iv: session.personalDataIv,
        authTag: session.personalDataTag,
      })

      return JSON.parse(decrypted) as SessionPersonalData
    } catch (error) {
      console.error("Failed to decrypt personal data:", error)
      return {}
    }
  }

  // Helper method to decrypt Apple push token
  private static decryptApplePushToken(session: DbSession): string | null {
    try {
      if (!session.applePushTokenEncrypted || !session.applePushTokenIv || !session.applePushTokenTag) {
        if (session.applePushToken) return session.applePushToken
        return null
      }

      return decrypt({
        encrypted: session.applePushTokenEncrypted,
        iv: session.applePushTokenIv,
        authTag: session.applePushTokenTag,
      })
    } catch (error) {
      console.error("Failed to decrypt push token:", error)
      return null
    }
  }

  // Get all active sessions for a user
  static async getValidSessionsByUserId(userId: number): Promise<SessionWithDecryptedData[]> {
    if (!userId || userId <= 0) {
      throw new Error("Invalid user ID")
    }

    try {
      const sessions_ = await db
        .select()
        .from(sessions)
        .where(and(eq(sessions.userId, userId), isNull(sessions.revoked)))

      // Validate sessions
      const validSessions = sessions_.filter((session) => session.revoked === null && session.userId === userId)

      return validSessions.map((session) => this.decryptSessionData(session))
    } catch (error) {
      throw new Error(`Failed to get active sessions: ${error instanceof Error ? error.message : "Unknown error"}`)
    }
  }

  // Get all currently active sessions for a user
  static async getActiveSessionsByUserId(userId: number): Promise<SessionWithDecryptedData[]> {
    if (!userId || userId <= 0) {
      throw new Error("Invalid user ID")
    }

    try {
      const sessions_ = await db
        .select()
        .from(sessions)
        .where(and(eq(sessions.userId, userId), isNull(sessions.revoked), eq(sessions.active, true)))

      // Validate sessions
      const validSessions = sessions_.filter((session) => session.revoked === null && session.userId === userId)

      return validSessions.map((session) => this.decryptSessionData(session))
    } catch (error) {
      throw new Error(`Failed to get active sessions: ${error instanceof Error ? error.message : "Unknown error"}`)
    }
  }
}
