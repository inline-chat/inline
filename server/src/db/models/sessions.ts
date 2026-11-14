// Note:Mostly AI generated

import { and, eq, inArray, isNotNull, isNull, ne, or } from "drizzle-orm"
import { sessions, type DbSession, type DbNewSession } from "@in/server/db/schema/sessions"
import { userNotDeleted, users } from "@in/server/db/schema/users"
import { encrypt, decrypt, keyedFingerprint } from "@in/server/modules/encryption/encryption"
import { db } from "@in/server/db"
import { Log } from "@in/server/utils/log"
import {
  revokeSession,
  finishSessionRevocation,
  revokeSessionInTransaction,
  type RevokeSessionInput,
  type RevokeSessionTransactionOutcome,
} from "@in/server/modules/sessions/revokeSession"
import { lockGridMutations } from "@in/server/modules/grid/roomLifecycle"
import type { Transaction } from "@in/server/db/types"
import type { SignupAttribution } from "@in/server/modules/auth/signupAttribution"

type SessionClientType = NonNullable<DbNewSession["clientType"]>
export type SessionPushNotificationProvider = "apns" | "expo_android"

// Define interfaces for the personal data structure
export interface SessionPersonalData {
  signupAttribution?: SignupAttribution
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

export interface UpdateSessionMetadataData {
  timezone?: string | undefined
  deviceName?: string | undefined
  clientVersion?: string | undefined
  osVersion?: string | undefined
}

export type SessionReplacement = {
  input: RevokeSessionInput
  outcome: RevokeSessionTransactionOutcome
}

export type TransactionalSessionCreateResult = {
  session: SessionWithDecryptedData
  replacement?: SessionReplacement
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

/** Push delivery fields cleared together whenever a session stops owning its push token. */
export const clearedPushNotificationDetails = {
  applePushToken: null,
  applePushTokenEncrypted: null,
  applePushTokenIv: null,
  applePushTokenTag: null,
  pushNotificationProvider: null,
  pushContentKeyPublic: null,
  pushContentKeyId: null,
  pushContentKeyAlgorithm: null,
  pushContentVersion: null,
  pushTokenFingerprint: null,
} satisfies Partial<DbNewSession>

/** Keyed fingerprint of a push token. Tokens are stored encrypted with random IVs; this is the lookup key. */
export const pushTokenFingerprint = (token: string): Buffer => keyedFingerprint("push-token.v1", token)

const isUniqueViolation = (error: unknown): boolean => {
  for (let cause: unknown = error, depth = 0; cause && depth < 4; depth++) {
    if (typeof cause === "object" && (cause as { code?: unknown }).code === "23505") return true
    cause = typeof cause === "object" ? (cause as { cause?: unknown }).cause : undefined
  }
  return false
}

export class SessionsModel {
  // Create a new session
  static async create(data: CreateSessionData): Promise<SessionWithDecryptedData> {
    const { session, replacement } = await db.transaction((tx) => this.createReplacingInTransaction(tx, data))
    if (replacement) {
      // Session creation has committed. A notification failure must not make a
      // successful login appear retryable or undo the durable replacement.
      await finishSessionRevocation(replacement.outcome, replacement.input).catch((cause) => {
        log.warn("Session replacement follow-up failed after commit", {
          errorName: cause instanceof Error ? cause.name : "UnknownError",
        })
      })
    }
    return session
  }

  /** Creates the session inside an existing authority transaction.
   * Any same-device session is revoked in that transaction so ticket use and
   * session replacement either both commit or both roll back.
   */
  static async createReplacingInTransaction(
    tx: Transaction,
    data: CreateSessionData,
    now = new Date(),
  ): Promise<TransactionalSessionCreateResult> {
    if (!data.userId || !data.tokenHash) {
      throw new Error("Missing required fields: userId and tokenHash are required")
    }

    let replacement: SessionReplacement | undefined
    if (data.deviceId) {
      await lockGridMutations(tx)
      const [existing] = await tx
        .select()
        .from(sessions)
        .where(and(eq(sessions.deviceId, data.deviceId), eq(sessions.userId, data.userId)))
        .for("update")
        .limit(1)
      if (existing) {
        const input: RevokeSessionInput = {
          actor: "system",
          targetUserId: data.userId,
          sessionId: existing.id,
        }
        replacement = {
          input,
          outcome: await revokeSessionInTransaction(tx, input, { releaseDeviceId: true }),
        }
      }
    }

    const [session] = await tx.insert(sessions).values(this.makeSessionData(data, now)).returning()
    if (!session) throw new Error("Failed to create session")
    return { session: this.decryptSessionData(session), replacement }
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

    if (!(await this.setActiveIfPresent(id, active))) {
      throw new Error(`Failed to update session last active: Session not found: ${id}`)
    }
  }

  static async setActiveIfPresent(id: number, active: boolean): Promise<boolean> {
    if (!id || id <= 0) {
      throw new Error("Invalid session ID")
    }

    try {
      const result = await db
        .update(sessions)
        .set({ active, lastActive: new Date() })
        .where(eq(sessions.id, id))
        .returning({ id: sessions.id })
      return result.length > 0
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

  /**
   * Refreshes activity cohorts without changing the legacy `active` flag.
   * Callers batch and coalesce ids before reaching this database boundary.
   */
  static async touchLastActiveBulk(ids: readonly number[]): Promise<void> {
    if (ids.length === 0) return

    try {
      await db
        .update(sessions)
        .set({ lastActive: new Date() })
        .where(inArray(sessions.id, [...ids]))
    } catch (error) {
      throw new Error(
        `Failed to touch sessions last active in bulk: ${error instanceof Error ? error.message : "Unknown error"}`,
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

    const fingerprint = pushTokenFingerprint(data.applePushToken)
    updateData.pushTokenFingerprint = fingerprint
    // A concurrent registration of the same token by another session can win the unique index
    // between our release and our update; the retry releases it from that session instead.
    for (let attempt = 0; ; attempt++) {
      try {
        await db.transaction((tx) => this.claimPushToken(tx, id, fingerprint, updateData))
        return
      } catch (error) {
        if (attempt === 0 && isUniqueViolation(error)) continue
        throw error
      }
    }
  }

  /**
   * A push token addresses one app install, and that install has one signed-in account. Any other
   * live session still holding this token (an earlier login of the same account, or another account
   * that left this device without reaching the server) would push with a key or account the device
   * no longer has, and the notification extension can only redact those. The database enforces one
   * live owner per token (`sessions_push_token_fingerprint_live`); registration takes it over.
   */
  private static async claimPushToken(
    tx: Transaction,
    id: number,
    fingerprint: Buffer,
    updateData: Partial<DbNewSession>,
  ): Promise<void> {
    const [owner] = await tx
      .select({ id: sessions.id })
      .from(sessions)
      .where(and(eq(sessions.id, id), isNull(sessions.revoked)))
      .for("update")
      .limit(1)
    if (!owner) return

    const released = await tx
      .update(sessions)
      .set(clearedPushNotificationDetails)
      .where(and(eq(sessions.pushTokenFingerprint, fingerprint), ne(sessions.id, id), isNull(sessions.revoked)))
      .returning({ id: sessions.id })
    await tx.update(sessions).set(updateData).where(eq(sessions.id, id))
    if (released.length > 0) {
      log.info("Released push token from superseded sessions", {
        ownerSessionId: id,
        releasedSessionIds: released.map((row) => row.id),
      })
    }
  }

  /**
   * Fingerprints live tokens registered before fingerprints existed and keeps one owner per token
   * (an owner registered since, else the newest session). Idempotent; runs once per server start.
   */
  static async backfillPushTokenFingerprints(): Promise<{ filled: number; released: number }> {
    const rows = await db
      .select({
        id: sessions.id,
        applePushToken: sessions.applePushToken,
        applePushTokenEncrypted: sessions.applePushTokenEncrypted,
        applePushTokenIv: sessions.applePushTokenIv,
        applePushTokenTag: sessions.applePushTokenTag,
        pushTokenFingerprint: sessions.pushTokenFingerprint,
      })
      .from(sessions)
      .where(
        and(
          isNull(sessions.revoked),
          or(isNotNull(sessions.applePushTokenEncrypted), isNotNull(sessions.applePushToken)),
        ),
      )
    if (!rows.some((row) => row.pushTokenFingerprint === null)) return { filled: 0, released: 0 }

    const groups = new Map<string, { id: number; registered: boolean }[]>()
    for (const row of rows) {
      const token = row.pushTokenFingerprint ? undefined : this.decryptApplePushToken(row)
      const fingerprint = row.pushTokenFingerprint ?? (token ? pushTokenFingerprint(token) : undefined)
      if (!fingerprint) continue
      const key = fingerprint.toString("hex")
      const group = groups.get(key) ?? []
      group.push({ id: row.id, registered: row.pushTokenFingerprint !== null })
      groups.set(key, group)
    }

    let filled = 0
    let released = 0
    for (const [key, group] of groups) {
      const owner = group.find((row) => row.registered) ?? group.reduce((a, b) => (b.id > a.id ? b : a))
      const losers = group.filter((row) => row !== owner).map((row) => row.id)
      if (losers.length > 0) {
        const cleared = await db
          .update(sessions)
          .set(clearedPushNotificationDetails)
          .where(and(inArray(sessions.id, losers), isNull(sessions.pushTokenFingerprint)))
          .returning({ id: sessions.id })
        released += cleared.length
      }
      if (owner.registered) continue
      try {
        const updated = await db
          .update(sessions)
          .set({ pushTokenFingerprint: Buffer.from(key, "hex") })
          .where(and(eq(sessions.id, owner.id), isNull(sessions.revoked), isNull(sessions.pushTokenFingerprint)))
          .returning({ id: sessions.id })
        filled += updated.length
      } catch (error) {
        if (!isUniqueViolation(error)) throw error
        // A registration claimed this token while we ran; it is the owner now.
        await db
          .update(sessions)
          .set(clearedPushNotificationDetails)
          .where(and(eq(sessions.id, owner.id), isNull(sessions.pushTokenFingerprint)))
        released += 1
      }
    }
    log.info("Backfilled push token fingerprints", { filled, released })
    return { filled, released }
  }

  /**
   * Clears a session's push registration after the provider rejected `token`, but only while the
   * session still holds that token: the device can re-register between the send and the failure.
   */
  static async releaseRejectedPushToken(id: number, token: string): Promise<boolean> {
    const cleared = await db
      .update(sessions)
      .set(clearedPushNotificationDetails)
      .where(
        and(
          eq(sessions.id, id),
          or(eq(sessions.pushTokenFingerprint, pushTokenFingerprint(token)), isNull(sessions.pushTokenFingerprint)),
        ),
      )
      .returning({ id: sessions.id })
    return cleared.length > 0
  }

  static async clearApplePushToken(id: number): Promise<void> {
    if (!id || id <= 0) {
      throw new Error("Invalid session ID")
    }

    await db
      .update(sessions)
      .set(clearedPushNotificationDetails)
      .where(eq(sessions.id, id))
  }

  static async updateMetadata(
    id: number,
    userId: number,
    data: UpdateSessionMetadataData,
  ): Promise<SessionWithDecryptedData> {
    const current = await this.getById(id)
    if (current.userId !== userId || current.revoked) throw new Error("Session not found")

    const personalData = {
      ...current.personalData,
      ...(data.timezone !== undefined ? { timezone: data.timezone } : {}),
      ...(data.deviceName !== undefined ? { deviceName: data.deviceName } : {}),
    }
    const encryptedPersonalData = encrypt(JSON.stringify(personalData))
    const [updated] = await db
      .update(sessions)
      .set({
        personalDataEncrypted: encryptedPersonalData.encrypted,
        personalDataIv: encryptedPersonalData.iv,
        personalDataTag: encryptedPersonalData.authTag,
        ...(data.clientVersion !== undefined ? { clientVersion: data.clientVersion } : {}),
        ...(data.osVersion !== undefined ? { osVersion: data.osVersion } : {}),
      })
      .where(and(eq(sessions.id, id), eq(sessions.userId, userId), isNull(sessions.revoked)))
      .returning()
    if (!updated) throw new Error("Session not found")
    return this.decryptSessionData(updated)
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

  private static makeSessionData(data: CreateSessionData, now: Date): DbNewSession {
    const encryptedPersonalData = encrypt(JSON.stringify(data.personalData))
    return {
      userId: data.userId,
      tokenHash: data.tokenHash,
      lastActive: now,
      date: now,
      deviceId: data.deviceId ?? null,
      personalDataEncrypted: encryptedPersonalData.encrypted,
      personalDataIv: encryptedPersonalData.iv,
      personalDataTag: encryptedPersonalData.authTag,
      // Push tokens are only set through updatePushNotificationDetails, which owns token uniqueness.
      clientType: data.clientType,
      clientVersion: data.clientVersion ?? null,
      osVersion: data.osVersion ?? null,
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
  private static decryptApplePushToken(
    session: Pick<DbSession, "applePushToken" | "applePushTokenEncrypted" | "applePushTokenIv" | "applePushTokenTag">,
  ): string | null {
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
