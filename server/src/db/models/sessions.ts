// Note:Mostly AI generated

import { and, eq, inArray, isNull } from "drizzle-orm"
import { sessions, type DbSession, type DbNewSession } from "@in/server/db/schema/sessions"
import { userNotDeleted, users } from "@in/server/db/schema/users"
import { encrypt, decrypt, type EncryptedData } from "@in/server/modules/encryption/encryption"
import { db } from "@in/server/db"
import { Log } from "@in/server/utils/log"
import { revokeSession } from "@in/server/modules/sessions/revokeSession"

type SessionClientType = NonNullable<DbNewSession["clientType"]>
export type SessionPushNotificationProvider = "apns" | "expo_android"

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
  pushNotificationProvider?: SessionPushNotificationProvider
  clientType: SessionClientType
  clientVersion?: string | undefined
  osVersion?: string | undefined
  deviceId?: string | undefined
}

export interface PushContentEncryptionKeyDetails {
  publicKey: Uint8Array
  keyId?: string | undefined
  algorithm?: string | undefined
}

export interface UpdatePushNotificationDetailsData {
  applePushToken: string
  pushNotificationProvider?: SessionPushNotificationProvider | undefined
  deviceId?: string | undefined
  pushContentEncryptionKey?: PushContentEncryptionKeyDetails | undefined
  pushContentVersion?: number | undefined
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

export interface IOSPushSession extends SessionWithDecryptedData {
  clientType: "ios"
  applePushToken: string
  pushNotificationProvider: "apns"
}

export interface PushSession extends SessionWithDecryptedData {
  applePushToken: string
  pushNotificationProvider: SessionPushNotificationProvider
}

const log = new Log("SessionsModel")

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
          pushNotificationProvider:
            data.pushNotificationProvider ?? this.defaultPushProviderForClientType(data.clientType),
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
          await revokeSession({
            actor: "system",
            targetUserId: data.userId,
            sessionId: existingDevice.id,
          })
          await db.delete(sessions).where(eq(sessions.id, existingDevice.id))
          log.info("Deleted previous session with matching device id", { userId: data.userId, sessionId: existingDevice.id })
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
    if (ids.length === 0) return

    try {
      await db.update(sessions).set({ active, lastActive: new Date() }).where(inArray(sessions.id, ids))
    } catch (error) {
      throw new Error(
        `Failed to update sessions last active in bulk: ${error instanceof Error ? error.message : "Unknown error"}`,
      )
    }
  }

  static async updateApplePushToken(id: number, applePushToken: string, deviceId?: string): Promise<void> {
    await this.updatePushNotificationDetails(id, {
      applePushToken,
      deviceId,
    })
  }

  static async updatePushNotificationDetails(id: number, data: UpdatePushNotificationDetailsData): Promise<void> {
    if (!id || id <= 0) {
      throw new Error("Invalid session ID")
    }
    if (!data.applePushToken || data.applePushToken.trim().length === 0) {
      throw new Error("Invalid push token")
    }

    const pushNotificationProvider = data.pushNotificationProvider ?? (await this.defaultPushProviderForSession(id))
    const encryptedApplePushToken = encrypt(data.applePushToken)
    const updateData: Partial<DbNewSession> = {
      applePushToken: null,
      applePushTokenEncrypted: encryptedApplePushToken.encrypted,
      applePushTokenIv: encryptedApplePushToken.iv,
      applePushTokenTag: encryptedApplePushToken.authTag,
      pushNotificationProvider,
      // Token-only updates must clear stale encrypted-push capability.
      pushContentKeyPublic: null,
      pushContentKeyId: null,
      pushContentKeyAlgorithm: null,
      pushContentVersion: null,
      ...(data.deviceId ? { deviceId: data.deviceId } : {}),
    }

    if (data.pushContentEncryptionKey) {
      updateData.pushContentKeyPublic = Buffer.from(data.pushContentEncryptionKey.publicKey)
      updateData.pushContentKeyId = data.pushContentEncryptionKey.keyId ?? null
      updateData.pushContentKeyAlgorithm = data.pushContentEncryptionKey.algorithm ?? null
    }

    if (data.pushContentVersion !== undefined) {
      updateData.pushContentVersion = data.pushContentVersion
    }

    await db
      .update(sessions)
      .set(updateData)
      .where(and(eq(sessions.id, id), isNull(sessions.revoked)))
  }

  static async clearApplePushToken(id: number): Promise<void> {
    if (!id || id <= 0) {
      throw new Error("Invalid session ID")
    }

    await db
      .update(sessions)
      .set({
        applePushToken: null,
        applePushTokenEncrypted: null,
        applePushTokenIv: null,
        applePushTokenTag: null,
        pushNotificationProvider: null,
        pushContentKeyPublic: null,
        pushContentKeyId: null,
        pushContentKeyAlgorithm: null,
        pushContentVersion: null,
      })
      .where(eq(sessions.id, id))
  }

  // Revoke a session
  static async revoke(id: number): Promise<void> {
    if (!id || id <= 0) {
      throw new Error("Invalid session ID")
    }

    try {
      const [session] = await db
        .select({ userId: sessions.userId })
        .from(sessions)
        .where(eq(sessions.id, id))
        .limit(1)
      if (!session) {
        throw new Error(`Session not found: ${id}`)
      }
      await revokeSession({
        actor: "system",
        targetUserId: session.userId,
        sessionId: id,
      })
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
      log.warn("Failed to decrypt personal data", error)
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
      log.warn("Failed to decrypt push token", error)
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

  static async getValidPushSessionsByUserId(userId: number): Promise<PushSession[]> {
    if (!userId || userId <= 0) {
      throw new Error("Invalid user ID")
    }

    try {
      const rows = await db
        .select({ session: sessions })
        .from(sessions)
        .innerJoin(users, eq(sessions.userId, users.id))
        .where(and(eq(sessions.userId, userId), isNull(sessions.revoked), userNotDeleted()))

      return rows
        .map((row) => this.decryptSessionData(row.session))
        .map((session) => this.toPushSession(session))
        .filter((session): session is PushSession => session !== undefined)
    } catch (error) {
      throw new Error(`Failed to get active push sessions: ${error instanceof Error ? error.message : "Unknown error"}`)
    }
  }

  static async getValidIOSPushSessionsByUserId(userId: number): Promise<IOSPushSession[]> {
    const pushSessions = await this.getValidPushSessionsByUserId(userId)
    return pushSessions.filter(this.isIOSPushSession)
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

  private static defaultPushProviderForClientType(clientType: SessionClientType): SessionPushNotificationProvider | null {
    if (clientType === "ios") return "apns"
    if (clientType === "android") return "expo_android"
    return null
  }

  private static async defaultPushProviderForSession(id: number): Promise<SessionPushNotificationProvider | null> {
    const [session] = await db
      .select({ clientType: sessions.clientType })
      .from(sessions)
      .where(and(eq(sessions.id, id), isNull(sessions.revoked)))
      .limit(1)

    return session?.clientType ? this.defaultPushProviderForClientType(session.clientType) : null
  }

  private static normalizedPushProvider(session: SessionWithDecryptedData): SessionPushNotificationProvider | null {
    if (session.pushNotificationProvider === "apns" || session.pushNotificationProvider === "expo_android") {
      return session.pushNotificationProvider
    }
    return session.clientType ? this.defaultPushProviderForClientType(session.clientType) : null
  }

  private static toPushSession(session: SessionWithDecryptedData): PushSession | undefined {
    if (session.revoked !== null || !session.applePushToken) return undefined

    const pushNotificationProvider = this.normalizedPushProvider(session)
    if (!pushNotificationProvider) return undefined

    return {
      ...session,
      applePushToken: session.applePushToken,
      pushNotificationProvider,
    }
  }

  private static isIOSPushSession(session: PushSession): session is IOSPushSession {
    return session.clientType === "ios" && session.pushNotificationProvider === "apns"
  }
}
