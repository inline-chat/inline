import { describe, expect, it } from "vitest"
import { effect } from "@inline/reactive"
import { userGesture, type UserGesture } from "../gesture"
import type { NotificationClick, Notifications } from "../platform"
import { createFakePlatform } from "./index"

const click = () => userGesture({ isTrusted: true, type: "click" }) as UserGesture
const notificationsOf = (fake: ReturnType<typeof createFakePlatform>) => {
  const capability = fake.platform.notifications
  if (!capability.available) throw new Error("expected notifications")
  return capability as Notifications
}

describe("fake platform", () => {
  it("records notifications, de-duplicates tags and drives clicks", () => {
    const fake = createFakePlatform()
    const n = notificationsOf(fake)
    const clicks: NotificationClick[] = []
    n.onClick((c) => clicks.push(c))
    expect(n.show({ tag: "a", title: "A", data: { chatId: "1" } })).toBe(true)
    expect(n.show({ tag: "a", title: "A again", data: { chatId: "1" } })).toBe(false)
    n.show({ tag: "b", title: "B", data: { chatId: "2" } })
    expect(fake.notifications.shown.map((r) => r.tag)).toEqual(["a", "b"])
    fake.notifications.click("a")
    expect(clicks).toEqual([{ tag: "a", data: { chatId: "1" } }])
    n.closeWhere((d) => d["chatId"] === "2")
    expect(fake.notifications.openTags()).toEqual([])
    expect(fake.notifications.closedTags).toEqual(["a", "b"])
    expect(() => fake.notifications.click("a")).toThrow()
  })

  it("asks for permission only from a gesture", async () => {
    const fake = createFakePlatform({ notificationPermission: "default", permissionAnswer: "denied" })
    const n = notificationsOf(fake)
    expect(await n.requestPermission({} as UserGesture)).toBe("default")
    expect(await n.requestPermission(click())).toBe("denied")
    expect(fake.notifications.permissionRequests).toBe(1)
    expect(n.show({ tag: "x", title: "x", data: {} })).toBe(false)
  })

  it("can be a context without notifications", () => {
    expect(createFakePlatform({ notificationsAvailable: false }).platform.notifications.available).toBe(false)
  })

  it("applies the real badge rule on its clock", () => {
    const fake = createFakePlatform()
    fake.platform.badge.set(2)
    fake.clock.advance(499)
    expect(fake.badge.applied).toEqual([])
    fake.clock.advance(1)
    fake.platform.badge.set(0)
    expect(fake.badge.applied).toEqual([2, 0])
    expect(fake.platform.badge.count.get()).toBe(0)
  })

  it("records links and saved files and delivers deep links", async () => {
    const fake = createFakePlatform({ initialDeepLink: "inline://chat/1" })
    const { links, files } = fake.platform
    expect(links.openExternal("https://inline.chat")).toBe(true)
    expect(links.openExternal("javascript:void 0")).toBe(false)
    expect(fake.links.opened).toEqual(["https://inline.chat"])
    expect(fake.links.refused).toEqual(["javascript:void 0"])
    const received: string[] = []
    links.onDeepLink((url) => received.push(url))
    fake.links.deliver("inline://chat/2")
    expect([links.initialDeepLink, ...received]).toEqual(["inline://chat/1", "inline://chat/2"])
    const blob = new Blob(["x"])
    expect(await files.save(blob, "a.txt")).toBe("downloaded")
    expect(fake.files.saved).toEqual([{ name: "a.txt", blob }])
  })

  it("lets a test drive visibility, focus, online state and freezes", () => {
    const fake = createFakePlatform()
    const { lifecycle } = fake.platform
    const seen: string[] = []
    const stop = effect(() => {
      seen.push(`${lifecycle.visible.get()}/${lifecycle.focused.get()}/${lifecycle.online.get()}`)
    })
    fake.lifecycle.setVisible(false)
    fake.lifecycle.setOnline(false)
    fake.lifecycle.setVisible(true)
    fake.lifecycle.setFocused(true)
    stop()
    expect(seen).toEqual(["true/true/true", "false/false/true", "false/false/false", "true/false/false", "true/true/false"])

    const freezes: string[] = []
    lifecycle.freezes.subscribe((e) => freezes.push(e))
    fake.lifecycle.pageHide(true)
    fake.lifecycle.freeze()
    fake.lifecycle.resume()
    expect(freezes).toEqual(["freeze", "resume"])
  })

  it("reports a wake when the test puts the machine to sleep", () => {
    const fake = createFakePlatform()
    const wakes: number[] = []
    fake.platform.lifecycle.onWake((e) => wakes.push(e.gapMs))
    fake.clock.advance(5 * 60_000)
    expect(wakes).toEqual([])
    fake.clock.sleep(60 * 60_000)
    expect(wakes).toHaveLength(1)
    fake.dispose()
    expect(fake.clock.pendingTimers()).toBe(0)
  })

  it("feeds the updater", () => {
    const fake = createFakePlatform()
    fake.updates.report({ status: "ready" })
    fake.platform.updater.apply()
    expect(fake.appliedUpdates).toBe(1)
  })

  it("as a desktop fake, makes desktop capabilities available and records them", () => {
    const fake = createFakePlatform({ desktop: true, os: "windows" })
    const { platform } = fake
    expect(platform.info).toEqual({ kind: "electron", os: "windows", shortcutModifier: "ctrl", surface: "window" })
    const n = notificationsOf(fake)
    expect([n.supportsActions, n.supportsInlineReply]).toEqual([true, true])
    if (!platform.window.newWindow.available || !platform.tray.available || !platform.files.reveal.available) {
      throw new Error("expected desktop capabilities")
    }
    platform.window.newWindow.open("/chat/1")
    platform.tray.setUnreadChats([{ title: "Mo", data: { chatId: "1" } }])
    platform.files.reveal.reveal("C:/a.txt")
    expect(fake.desktop.windowsOpened).toEqual(["/chat/1"])
    expect(fake.desktop.trayChats).toEqual([[{ title: "Mo", data: { chatId: "1" } }]])
    expect(fake.files.revealed).toEqual(["C:/a.txt"])
    expect(platform.window.titleBarOverlay.available).toBe(true)

    const actions: string[] = []
    n.onAction((e) => actions.push(`${e.actionId}:${e.reply ?? ""}`))
    n.show({ tag: "m", title: "m", data: {} })
    fake.notifications.action("m", "reply", "on it")
    expect(actions).toEqual(["reply:on it"])
  })

  it("as a Linux desktop fake, has no inline reply", () => {
    const n = notificationsOf(createFakePlatform({ desktop: true, os: "linux" }))
    expect(n.supportsInlineReply).toBe(false)
  })
})
