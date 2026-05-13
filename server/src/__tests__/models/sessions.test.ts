import { describe, expect, test } from "bun:test"
import { eq } from "drizzle-orm"
import { db, schema } from "@in/server/db"
import { SessionsModel } from "@in/server/db/models/sessions"
import { setupTestLifecycle, testUtils } from "../setup"

describe("SessionsModel push sessions", () => {
  setupTestLifecycle()

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
    expect(row?.pushContentKeyPublic).toBeNull()
    expect(row?.pushContentKeyId).toBeNull()
    expect(row?.pushContentKeyAlgorithm).toBeNull()
    expect(row?.pushContentVersion).toBeNull()

    await expect(SessionsModel.getValidIOSPushSessionsByUserId(user.id)).resolves.toEqual([])
  })
})
