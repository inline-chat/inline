import { expect, spyOn, test } from "bun:test"
import { setupTestLifecycle, testUtils } from "@in/server/__tests__/setup"
import { SessionsModel } from "@in/server/db/models/sessions"
import * as apn from "@in/server/libs/apn"
import * as expo from "@in/server/libs/expoPush"
import { applicationBackgroundWork } from "@in/server/lifecycle/backgroundWork"
import { Notifications } from "@in/server/modules/notifications/notifications"

setupTestLifecycle()

test("prepared push submission starts every device before waiting for a slow provider", async () => {
  const user = await testUtils.createUser("prepared-push@example.test")
  const first = await testUtils.createSessionForUser(user.id, { clientType: "ios", deviceId: "prepared-ios-first" })
  const second = await testUtils.createSessionForUser(user.id, { clientType: "ios", deviceId: "prepared-ios-second" })
  const android = await testUtils.createSessionForUser(user.id, { clientType: "android", deviceId: "prepared-android" })
  await SessionsModel.updatePushNotificationDetails(first.session.id, { applePushToken: "prepared-apns-first" })
  await SessionsModel.updatePushNotificationDetails(second.session.id, { applePushToken: "prepared-apns-second" })
  await SessionsModel.updatePushNotificationDetails(android.session.id, {
    applePushToken: "ExponentPushToken[prepared-android]", pushNotificationProvider: "expo_android",
  })
  const started: string[] = []
  const slow = Promise.withResolvers<{ sent: never[]; failed: never[] }>()
  const provider = {
    send(_notification: unknown, token: string) {
      started.push(`apns:${token}`)
      return token === "prepared-apns-first" ? slow.promise : Promise.resolve({ sent: [], failed: [] })
    },
  }
  const expoClient = {
    chunkPushNotifications(messages: expo.ExpoPushMessage[]) { return [messages] },
    sendPushNotificationsAsync(messages: expo.ExpoPushMessage[]) {
      started.push(`expo:${messages[0]?.to}`)
      return Promise.resolve([{ status: "ok", id: "prepared-expo-ticket" }])
    },
  }
  const apnProvider = spyOn(apn, "getApnProvider").mockReturnValue(provider as unknown as ReturnType<typeof apn.getApnProvider>)
  const expoProvider = spyOn(expo, "getExpoPushClient").mockReturnValue(expoClient as unknown as ReturnType<typeof expo.getExpoPushClient>)
  let submitted: Promise<void> | undefined
  try {
    const submit = await Notifications.prepareSendToUser({
      userId: user.id,
      payload: { kind: "alert", senderUserId: user.id, threadId: "prepared-test", title: "Prepared", body: "Ready" },
    })
    expect(submit).toBeDefined()
    expect(started).toEqual([])
    submitted = submit!()
    expect(new Set(started)).toEqual(new Set([
      "apns:prepared-apns-first", "apns:prepared-apns-second", "expo:ExponentPushToken[prepared-android]",
    ]))
    // APNs remains detached from generic callers, but the lifecycle registry
    // must own the slow provider result until it completes.
    await submitted
    let drained = false
    const draining = applicationBackgroundWork.waitForIdle().then(() => { drained = true })
    await Promise.resolve()
    expect(drained).toBe(false)
    slow.resolve({ sent: [], failed: [] })
    await draining
    expect(drained).toBe(true)
  } finally {
    slow.resolve({ sent: [], failed: [] })
    await submitted
    await applicationBackgroundWork.waitForIdle()
    apnProvider.mockRestore()
    expoProvider.mockRestore()
  }
})

test("push preparation returns no submission for a user without push devices", async () => {
  const user = await testUtils.createUser("unprepared-push@example.test")
  expect(await Notifications.prepareSendToUser({
    userId: user.id,
    payload: { kind: "alert", senderUserId: user.id, threadId: "prepared-test", title: "Prepared", body: "Ready" },
  })).toBeUndefined()
})
