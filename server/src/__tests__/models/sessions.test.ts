import { describe, expect, spyOn, test } from "bun:test"
import { eq, inArray } from "drizzle-orm"
import { db, schema } from "@in/server/db"
import { SessionsModel } from "@in/server/db/models/sessions"
import { encrypt } from "@in/server/modules/encryption/encryption"
import { alertAllowedByNotificationSettings } from "@in/server/modules/notifications/sendToUser"
import { UserSettingsNotificationsMode } from "@in/server/db/models/userSettings/types"
import { setupTestLifecycle, testUtils } from "../setup"
import { connectionManager } from "@in/server/ws/connections"

describe("SessionsModel push sessions", () => {
  setupTestLifecycle()

  test("concurrent same-device login replaces authority atomically", async () => {
    const user = await testUtils.createUser("session-race@example.com")
    const close = spyOn(connectionManager, "closeConnectionForSession")
    try {
      const results = await Promise.all(Array.from({ length: 2 }, () =>
        testUtils.createSessionForUser(user.id, { deviceId: "same-device" })))
      const rows = await db.select().from(schema.sessions).where(eq(schema.sessions.userId, user.id))
      expect(results).toHaveLength(2)
      expect(rows).toHaveLength(2)
      expect(rows.filter((row) => !row.revoked)).toHaveLength(1)
      const revoked = rows.find((row) => row.revoked)!
      expect(revoked.deviceId).toBeNull()
      expect(close).toHaveBeenCalledWith(user.id, revoked.id, { authenticationInvalidated: true }, undefined)
    } finally {
      close.mockRestore()
    }
  })

  test("failed replacement insert preserves the previous live authority", async () => {
    const user = await testUtils.createUser("session-rollback@example.com")
    const previous = await testUtils.createSessionForUser(user.id, { deviceId: "rollback-device" })
    await expect(SessionsModel.create({
      userId: user.id, deviceId: "rollback-device", tokenHash: "x".repeat(65), personalData: {}, clientType: "web",
    })).rejects.toThrow()
    const rows = await db.select().from(schema.sessions).where(eq(schema.sessions.userId, user.id))
    expect(rows).toHaveLength(1)
    expect(rows[0]?.id).toBe(previous.session.id)
    expect(rows[0]?.revoked).toBeNull()
    expect(rows[0]?.deviceId).toBe("rollback-device")
  })

  test("returns only non-revoked iOS sessions with push tokens", async () => {
    const user = await testUtils.createUser("push-sessions@test.com")
    const active = await testUtils.createSessionForUser(user.id, { clientType: "ios" })
    const revoked = await testUtils.createSessionForUser(user.id, { clientType: "ios" })
    const noToken = await testUtils.createSessionForUser(user.id, { clientType: "ios" })
    const macos = await testUtils.createSessionForUser(user.id, { clientType: "macos" })

    await SessionsModel.updatePushNotificationDetails(active.session.id, { applePushToken: "active-ios-token" })
    await SessionsModel.updatePushNotificationDetails(revoked.session.id, { applePushToken: "revoked-ios-token" })
    await SessionsModel.updatePushNotificationDetails(macos.session.id, { applePushToken: "macos-token" })

    await db
      .update(schema.sessions)
      .set({ revoked: new Date() })
      .where(eq(schema.sessions.id, revoked.session.id))

    const pushSessions = await SessionsModel.getValidIOSPushSessionsByUserId(user.id)

    expect(pushSessions.map((session) => session.id)).toEqual([active.session.id])
    expect(pushSessions[0]?.applePushToken).toBe("active-ios-token")
    expect(pushSessions.some((session) => session.id === noToken.session.id)).toBe(false)
  })

  test("returns Android Expo sessions through provider-aware push lookup", async () => {
    const user = await testUtils.createUser("android-push-sessions@test.com")
    const ios = await testUtils.createSessionForUser(user.id, { clientType: "ios" })
    const android = await testUtils.createSessionForUser(user.id, { clientType: "android" })
    const macos = await testUtils.createSessionForUser(user.id, { clientType: "macos" })

    await SessionsModel.updatePushNotificationDetails(ios.session.id, { applePushToken: "ios-token" })
    await SessionsModel.updatePushNotificationDetails(android.session.id, {
      applePushToken: "ExponentPushToken[android-token]",
      pushNotificationProvider: "expo_android",
    })
    await SessionsModel.updatePushNotificationDetails(macos.session.id, { applePushToken: "macos-token" })

    const pushSessions = await SessionsModel.getValidPushSessionsByUserId(user.id)
    const iosPushSessions = await SessionsModel.getValidIOSPushSessionsByUserId(user.id)

    expect(pushSessions.map((session) => [session.id, session.pushNotificationProvider])).toEqual([
      [ios.session.id, "apns"],
      [android.session.id, "expo_android"],
    ])
    expect(pushSessions.find((session) => session.id === android.session.id)?.applePushToken).toBe(
      "ExponentPushToken[android-token]",
    )
    expect(iosPushSessions.map((session) => session.id)).toEqual([ios.session.id])
  })

  test("infers provider for legacy push rows without provider metadata", async () => {
    const user = await testUtils.createUser("legacy-push-sessions@test.com")
    const ios = await testUtils.createSessionForUser(user.id, { clientType: "ios" })
    const android = await testUtils.createSessionForUser(user.id, { clientType: "android" })

    await SessionsModel.updatePushNotificationDetails(ios.session.id, { applePushToken: "ios-token" })
    await SessionsModel.updatePushNotificationDetails(android.session.id, {
      applePushToken: "ExponentPushToken[android-token]",
      pushNotificationProvider: "expo_android",
    })
    await db
      .update(schema.sessions)
      .set({ pushNotificationProvider: null })
      .where(eq(schema.sessions.userId, user.id))

    const pushSessions = await SessionsModel.getValidPushSessionsByUserId(user.id)

    expect(pushSessions.map((session) => [session.id, session.pushNotificationProvider])).toEqual([
      [ios.session.id, "apns"],
      [android.session.id, "expo_android"],
    ])
  })

  test("does not update push details for revoked sessions", async () => {
    const user = await testUtils.createUser("revoked-push-update@test.com")
    const session = await testUtils.createSessionForUser(user.id, { clientType: "ios" })

    await db
      .update(schema.sessions)
      .set({ revoked: new Date() })
      .where(eq(schema.sessions.id, session.session.id))

    await SessionsModel.updatePushNotificationDetails(session.session.id, { applePushToken: "late-token" })

    const [row] = await db
      .select({ applePushTokenEncrypted: schema.sessions.applePushTokenEncrypted })
      .from(schema.sessions)
      .where(eq(schema.sessions.id, session.session.id))
      .limit(1)

    expect(row?.applePushTokenEncrypted).toBeNull()
  })

  test("treats a missing session as a normal conditional active update", async () => {
    await expect(SessionsModel.setActiveIfPresent(2_000_000_000, false)).resolves.toBe(false)
  })

  test("a push token belongs to one live session", async () => {
    const user = await testUtils.createUser("push-token-owner@test.com")
    const other = await testUtils.createUser("push-token-other@test.com")
    const bystander = await testUtils.createUser("push-token-bystander@test.com")
    const macUser = await testUtils.createUser("push-token-mac@test.com")
    const earlier = await testUtils.createSessionForUser(user.id, { clientType: "ios" })
    const reinstall = await testUtils.createSessionForUser(user.id, { clientType: "ios", deviceId: "device-a" })
    const otherAccount = await testUtils.createSessionForUser(other.id, { clientType: "ios", deviceId: "device-a" })
    const otherMac = await testUtils.createSessionForUser(macUser.id, { clientType: "macos", deviceId: "device-a" })
    // Another account that once signed in on this install, before device IDs or under an earlier one.
    const leftBeforeDeviceIDs = await testUtils.createSessionForUser(bystander.id, { clientType: "ios" })

    // Same token on an earlier login and on another account that left this device.
    await SessionsModel.updatePushNotificationDetails(earlier.session.id, { applePushToken: "token-a" })
    await SessionsModel.updatePushNotificationDetails(otherAccount.session.id, { applePushToken: "token-a" })
    // A different token under the same device ID can be another Inline bundle (debug, devbuild).
    const debugUser = await testUtils.createUser("push-token-debug@test.com")
    const otherBundle = await testUtils.createSessionForUser(debugUser.id, { clientType: "ios", deviceId: "device-a" })
    await SessionsModel.updatePushNotificationDetails(otherBundle.session.id, { applePushToken: "debug-token" })
    await SessionsModel.updatePushNotificationDetails(otherMac.session.id, {
      applePushToken: "mac-token",
      pushNotificationProvider: "apns",
    })
    await SessionsModel.updatePushNotificationDetails(leftBeforeDeviceIDs.session.id, { applePushToken: "token-a" })
    const elsewhere = await testUtils.createUser("push-token-elsewhere@test.com")
    const elsewhereSession = await testUtils.createSessionForUser(elsewhere.id, {
      clientType: "ios",
      deviceId: "device-b",
    })
    await SessionsModel.updatePushNotificationDetails(elsewhereSession.session.id, { applePushToken: "token-b" })

    await SessionsModel.updatePushNotificationDetails(reinstall.session.id, { applePushToken: "token-a" })

    const tokens = async (userId: number) =>
      (await SessionsModel.getValidPushSessionsByUserId(userId)).map((session) => [session.id, session.applePushToken])
    expect(await tokens(user.id)).toEqual([[reinstall.session.id, "token-a"]])
    // Another client type on the same device keeps its own token.
    expect(await tokens(other.id)).toEqual([])
    expect(await tokens(macUser.id)).toEqual([[otherMac.session.id, "mac-token"]])
    expect(await tokens(debugUser.id)).toEqual([[otherBundle.session.id, "debug-token"]])
    // The token is matched globally: an account that left this install under no or another device
    // ID would otherwise keep pushing its messages here, redacted to "Open Inline to read it."
    expect(await tokens(bystander.id)).toEqual([])
    expect(await tokens(elsewhere.id)).toEqual([[elsewhereSession.session.id, "token-b"]])
  })

  test("revoke clears push notification details", async () => {
    const user = await testUtils.createUser("revoke-clears-push@test.com")
    const session = await testUtils.createSessionForUser(user.id, { clientType: "ios" })
    const publicKey = new Uint8Array(Array.from({ length: 32 }, (_, index) => index + 1))

    await SessionsModel.updatePushNotificationDetails(session.session.id, {
      applePushToken: "ios-token",
      pushContentEncryptionKey: {
        publicKey,
        keyId: "key-v1",
        algorithm: "X25519_HKDF_SHA256_AES256_GCM",
      },
      pushContentVersion: 1,
    })
    await SessionsModel.setActive(session.session.id, true)

    await SessionsModel.revoke(session.session.id)

    const [row] = await db
      .select({
        revoked: schema.sessions.revoked,
        active: schema.sessions.active,
        applePushToken: schema.sessions.applePushToken,
        applePushTokenEncrypted: schema.sessions.applePushTokenEncrypted,
        applePushTokenIv: schema.sessions.applePushTokenIv,
        applePushTokenTag: schema.sessions.applePushTokenTag,
        pushNotificationProvider: schema.sessions.pushNotificationProvider,
        pushContentKeyPublic: schema.sessions.pushContentKeyPublic,
        pushContentKeyId: schema.sessions.pushContentKeyId,
        pushContentKeyAlgorithm: schema.sessions.pushContentKeyAlgorithm,
        pushContentVersion: schema.sessions.pushContentVersion,
      })
      .from(schema.sessions)
      .where(eq(schema.sessions.id, session.session.id))
      .limit(1)

    expect(row?.revoked).not.toBeNull()
    expect(row?.active).toBe(false)
    expect(row?.applePushToken).toBeNull()
    expect(row?.applePushTokenEncrypted).toBeNull()
    expect(row?.applePushTokenIv).toBeNull()
    expect(row?.applePushTokenTag).toBeNull()
    expect(row?.pushNotificationProvider).toBeNull()
    expect(row?.pushContentKeyPublic).toBeNull()
    expect(row?.pushContentKeyId).toBeNull()
    expect(row?.pushContentKeyAlgorithm).toBeNull()
    expect(row?.pushContentVersion).toBeNull()

    await expect(SessionsModel.getValidIOSPushSessionsByUserId(user.id)).resolves.toEqual([])
  })

  test("concurrent registrations of one token leave exactly one owner", async () => {
    const first = await testUtils.createUser("push-race-a@test.com")
    const second = await testUtils.createUser("push-race-b@test.com")
    const a = await testUtils.createSessionForUser(first.id, { clientType: "ios" })
    const b = await testUtils.createSessionForUser(second.id, { clientType: "ios" })

    await Promise.all([
      SessionsModel.updatePushNotificationDetails(a.session.id, { applePushToken: "raced-token" }),
      SessionsModel.updatePushNotificationDetails(b.session.id, { applePushToken: "raced-token" }),
    ])

    const owners = [
      ...(await SessionsModel.getValidPushSessionsByUserId(first.id)),
      ...(await SessionsModel.getValidPushSessionsByUserId(second.id)),
    ]
    expect(owners.map((session) => session.applePushToken)).toEqual(["raced-token"])
  })

  test("a rejected token is released only while the session still holds it", async () => {
    const user = await testUtils.createUser("push-reject@test.com")
    const session = await testUtils.createSessionForUser(user.id, { clientType: "ios" })
    await SessionsModel.updatePushNotificationDetails(session.session.id, { applePushToken: "old-token" })
    // The device re-registers between a send and that send's failure.
    await SessionsModel.updatePushNotificationDetails(session.session.id, { applePushToken: "new-token" })

    expect(await SessionsModel.releaseRejectedPushToken(session.session.id, "old-token")).toBe(false)
    expect((await SessionsModel.getValidPushSessionsByUserId(user.id))[0]?.applePushToken).toBe("new-token")

    expect(await SessionsModel.releaseRejectedPushToken(session.session.id, "new-token")).toBe(true)
    expect(await SessionsModel.getValidPushSessionsByUserId(user.id)).toEqual([])
  })

  test("backfill fingerprints tokens registered before fingerprints and keeps one owner per token", async () => {
    const users = await Promise.all(
      ["shared-old", "shared-new", "registered", "legacy-claimer", "unique"].map((name) =>
        testUtils.createUser(`push-backfill-${name}@test.com`)),
    )
    // Sequential: "newest" is the higher session id.
    const created = []
    for (const user of users) created.push(await testUtils.createSessionForUser(user.id, { clientType: "ios" }))
    const [sharedOld, sharedNew, registered, legacyClaimer, unique] = created
    // Rows written by the previous server: encrypted token, no fingerprint.
    const legacyToken = async (sessionId: number, token: string) => {
      const encrypted = encrypt(token)
      await db
        .update(schema.sessions)
        .set({
          applePushTokenEncrypted: encrypted.encrypted,
          applePushTokenIv: encrypted.iv,
          applePushTokenTag: encrypted.authTag,
          pushNotificationProvider: "apns",
          pushTokenFingerprint: null,
        })
        .where(eq(schema.sessions.id, sessionId))
    }
    await legacyToken(sharedOld!.session.id, "shared-token")
    await legacyToken(sharedNew!.session.id, "shared-token")
    await legacyToken(legacyClaimer!.session.id, "claimed-token")
    await legacyToken(unique!.session.id, "unique-token")
    // A registration through the new server after deploy owns its token over any legacy row.
    await SessionsModel.updatePushNotificationDetails(registered!.session.id, { applePushToken: "claimed-token" })

    expect(await SessionsModel.backfillPushTokenFingerprints()).toEqual({ filled: 2, released: 2 })
    expect(await SessionsModel.backfillPushTokenFingerprints()).toEqual({ filled: 0, released: 0 })

    const token = async (index: number) =>
      (await SessionsModel.getValidPushSessionsByUserId(users[index]!.id))[0]?.applePushToken ?? null
    // Among legacy rows the newest session keeps the token.
    expect(await token(0)).toBeNull()
    expect(await token(1)).toBe("shared-token")
    expect(await token(2)).toBe("claimed-token")
    expect(await token(3)).toBeNull()
    expect(await token(4)).toBe("unique-token")
    const rows = await db
      .select({ id: schema.sessions.id, fingerprint: schema.sessions.pushTokenFingerprint })
      .from(schema.sessions)
      .where(inArray(schema.sessions.id, [sharedNew!.session.id, unique!.session.id]))
    expect(rows.every((row) => row.fingerprint !== null)).toBe(true)
  })

  test("alerts follow the recipient's notification mode", async () => {
    const settings = (mode: UserSettingsNotificationsMode) =>
      ({ notifications: { mode, silent: false, disableDmNotifications: false } }) as Parameters<
        typeof alertAllowedByNotificationSettings
      >[1]
    expect(await alertAllowedByNotificationSettings(1, settings(UserSettingsNotificationsMode.All), undefined)).toBe(true)
    expect(await alertAllowedByNotificationSettings(1, settings(UserSettingsNotificationsMode.Mentions), undefined)).toBe(
      true,
    )
    expect(await alertAllowedByNotificationSettings(1, settings(UserSettingsNotificationsMode.None), undefined)).toBe(
      false,
    )
    expect(await alertAllowedByNotificationSettings(1, undefined, undefined)).toBe(true)
  })
})
