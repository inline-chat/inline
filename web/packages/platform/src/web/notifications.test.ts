// @vitest-environment happy-dom
import { describe, expect, it } from "vitest"
import { userGesture, type UserGesture } from "../gesture"
import type { NotificationClick, Notifications } from "../platform"
import { createWebNotifications, SHOWN_TAG_MEMORY } from "./notifications"
import { flush, makeTestEnv } from "./web-env.fixture"

const click = () => userGesture({ isTrusted: true, type: "click" }) as UserGesture

const setup = (permission = "granted") => {
  const t = makeTestEnv({ notificationPermission: permission })
  const created = createWebNotifications(t.env)
  if (!created.capability.available) throw new Error("expected notifications")
  return { t, n: created.capability as Notifications, dispose: created.dispose }
}

const message = (tag: string, chatId = "1") => ({
  tag,
  title: "Mo",
  body: "hello",
  data: { chatId, messageId: tag },
})

describe("web notifications", () => {
  it("is unavailable without the Notification API", () => {
    const t = makeTestEnv({ notifications: false })
    expect(createWebNotifications(t.env).capability).toEqual({ available: false, reason: "no-notification-api" })
  })

  it("never prompts without a user gesture", async () => {
    const { t, n } = setup("default")
    const forged = { eventType: "click" } as unknown as UserGesture
    expect(await n.requestPermission(forged)).toBe("default")
    expect(t.notifications.state.requests).toBe(0)
  })

  it("prompts from a gesture and publishes the answer", async () => {
    const { t, n } = setup("default")
    expect(n.permission.get()).toBe("default")
    t.notifications.state.answer = "denied"
    expect(await n.requestPermission(click())).toBe("denied")
    expect(n.permission.get()).toBe("denied")
    expect(t.notifications.state.requests).toBe(1)
  })

  it("does not prompt again once decided", async () => {
    const { t, n } = setup("denied")
    expect(await n.requestPermission(click())).toBe("denied")
    expect(t.notifications.state.requests).toBe(0)
  })

  it("follows permission changes made in browser settings", async () => {
    const { t, n } = setup("granted")
    await flush()
    t.notifications.state.permission = "denied"
    t.permissionStatus.change("denied")
    expect(n.permission.get()).toBe("denied")
  })

  it("shows only with permission", () => {
    const { t, n } = setup("default")
    expect(n.show(message("a"))).toBe(false)
    expect(t.notifications.instances).toHaveLength(0)
  })

  it("passes the tag and options through", () => {
    const { t, n } = setup()
    expect(n.show({ ...message("chat_1_message_9"), icon: "/a.png", silent: true, urgent: true })).toBe(true)
    expect(t.notifications.instances[0]?.title).toBe("Mo")
    expect(t.notifications.instances[0]?.options).toEqual({
      tag: "chat_1_message_9",
      body: "hello",
      icon: "/a.png",
      silent: true,
      requireInteraction: true,
    })
  })

  it("shows a tag once per context, even after it closed", () => {
    const { t, n } = setup()
    expect(n.show(message("x"))).toBe(true)
    expect(n.show(message("x"))).toBe(false)
    n.close("x")
    expect(n.show(message("x"))).toBe(false)
    expect(t.notifications.instances).toHaveLength(1)
  })

  it("forgets the oldest tags beyond its memory", () => {
    const { n } = setup()
    for (let i = 0; i <= SHOWN_TAG_MEMORY; i++) n.show(message(`t${i}`))
    expect(n.show(message("t0"))).toBe(true)
    expect(n.show(message(`t${SHOWN_TAG_MEMORY}`))).toBe(false)
  })

  it("a click focuses the window, closes it and reports its data", () => {
    const { t, n } = setup()
    const clicks: NotificationClick[] = []
    n.onClick((c) => clicks.push(c))
    n.show(message("m1", "42"))
    t.notifications.instances[0]?.onclick?.({})
    expect(t.focusCalls.count).toBe(1)
    expect(t.notifications.instances[0]?.closed).toBe(true)
    expect(clicks).toEqual([{ tag: "m1", data: { chatId: "42", messageId: "m1" } }])
  })

  it("closes by tag and by data", () => {
    const { t, n } = setup()
    n.show(message("a", "1"))
    n.show(message("b", "2"))
    n.show(message("c", "2"))
    n.close("a")
    expect(t.notifications.instances.map((i) => i.closed)).toEqual([true, false, false])
    n.closeWhere((data) => data["chatId"] === "2")
    expect(t.notifications.instances.map((i) => i.closed)).toEqual([true, true, true])
  })

  it("forgets a notification the user dismissed", () => {
    const { t, n } = setup()
    n.show(message("a"))
    t.notifications.instances[0]?.close()
    n.close("a")
    expect(t.notifications.instances[0]?.closed).toBe(true)
  })

  it("returns false when the constructor throws (Android Chrome)", () => {
    const { t, n } = setup()
    t.notifications.state.throwOnCreate = true
    expect(n.show(message("a"))).toBe(false)
    t.notifications.state.throwOnCreate = false
    expect(n.show(message("a"))).toBe(true)
  })

  it("has no actions or inline reply on the web", () => {
    const { n } = setup()
    expect(n.supportsActions).toBe(false)
    expect(n.supportsInlineReply).toBe(false)
    expect(typeof n.onAction(() => {})).toBe("function")
  })

  it("shows nothing after dispose", () => {
    const { n, dispose } = setup()
    dispose()
    expect(n.show(message("a"))).toBe(false)
  })
})
