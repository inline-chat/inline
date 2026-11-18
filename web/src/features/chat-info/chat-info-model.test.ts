import type { ChatRow, DialogRow, UserRow } from "@inline/core-protocol"
import { memberRowId, rowKey } from "@inline/core-protocol"
import { chatId as toChatId, spaceId as toSpaceId, userId as toUserId, type DialogID, type UserID } from "@inline/ids"
import { computed, effect, signal, type ReadSignal } from "@inline/reactive"
import { IntentTracker } from "@inline/view/features"
import { afterEach, describe, expect, it } from "vitest"
import { createChatInfoModel, WAITING_TEXT, type ChatInfoModel, type ControlId } from "./chat-info-model"
import { testHarness, type IntentMode, type TestHarness } from "./testing"

const uid = (n: number) => toUserId(String(n))
const cid = (n: number) => toChatId(String(n))
const space = toSpaceId("7")
const me = uid(1)

const users: UserRow[] = [
  { kind: "user", id: me, firstName: "Mo" },
  { kind: "user", id: uid(2), firstName: "Ada", lastName: "Lovelace", username: "ada" },
  { kind: "user", id: uid(3), firstName: "Helper", bot: true },
]
const thread: ChatRow = { kind: "chat", id: cid(10), title: "Launch plan", emoji: "🚀", spaceId: space }
const direct: ChatRow = { kind: "chat", id: cid(20), peerUserId: uid(2) }
const botChat: ChatRow = { kind: "chat", id: cid(30), peerUserId: uid(3) }
const dialogOf = (chat: ChatRow, extra: Partial<DialogRow> = {}): DialogRow => ({
  kind: "dialog",
  id: `d${chat.id}` as DialogID,
  chatId: chat.id,
  pinned: false,
  archived: false,
  open: true,
  unreadCount: 0,
  unreadMark: false,
  ...extra,
})

let h: TestHarness | undefined
let model: ChatInfoModel | undefined
let tracker: IntentTracker | undefined
afterEach(() => {
  model?.dispose()
  tracker?.dispose()
  h?.dispose()
  model = undefined
  tracker = undefined
  h = undefined
})

const setup = async (chat: ChatRow = thread, extra: { offline?: ReadSignal<boolean>; copied?: string[]; opened?: UserID[] } = {}) => {
  h = testHarness({ me })
  h.core.setUsers(users)
  for (const row of [thread, direct, botChat]) {
    h.core.setChat(row)
    h.core.setDialog(dialogOf(row))
  }
  h.core.setParticipants(thread.id, [me, uid(2), uid(3)])
  // The dialog arrives with the sidebar in the app.
  h.client.subscribe({ kind: "sidebar", mode: "all" })
  const dialogKey = rowKey("dialog", `d${chat.id}`)
  const sidebarDialog = computed(() => h!.client.store.rowByKey(dialogKey).get() as DialogRow | undefined)
  tracker = new IntentTracker({ core: h.core.endpoint, store: h.client.store })
  model = createChatInfoModel({
    client: h.client,
    chatId: chat.id,
    viewerId: me,
    dialog: sidebarDialog,
    intents: tracker,
    ...(extra.offline ? { offline: extra.offline } : {}),
    onOpenProfile: (id) => extra.opened?.push(id),
    copyText: (text) => {
      extra.copied?.push(text)
    },
    clock: h.time,
  })
  const stop = effect(() => {
    model!.header.get()
    model!.settings.get()
    model!.participants.ids.get()
    model!.tabs.get()
  })
  await h.flush()
  return { t: h, m: model, stop }
}

/** Run a control under an intent mode and collect the states it went through. */
const watchControl = (m: ChatInfoModel, id: ControlId) => {
  const seen: string[] = []
  const stop = effect(() => {
    const state = m.control(id).get()
    seen.push(state.kind === "failed" || state.kind === "uncertain" ? `${state.kind}:${state.notice.kind}` : state.kind)
  })
  return { seen, stop }
}

describe("chat info: header and tabs", () => {
  it("shows a thread's title, kind, participant count and ID, with the Mac's tabs and settings last", async () => {
    const { m, stop } = await setup()
    expect(m.header.peek()).toEqual({
      title: "Launch plan",
      kindLabel: "Private thread",
      countText: "3 participants",
      avatar: { kind: "chat", chatId: thread.id, seed: "Launch plan", emoji: "🚀" },
      chatIdText: "10",
    })
    expect(m.tabs.peek().map((tab) => tab.id)).toEqual(["participants", "media", "files", "voice", "links", "settings"])
    expect(m.tabsController.selectedId.peek()).toBe("participants")
    stop()
  })

  it("shows a direct message with the peer's name and no participants tab, and a bot as a bot", async () => {
    const { m, stop } = await setup(direct)
    expect(m.header.peek()).toMatchObject({ title: "Ada Lovelace", kindLabel: "Direct message", avatar: { kind: "user", userId: uid(2) } })
    expect(m.header.peek().countText).toBeUndefined()
    // The Mac's tabs for a direct message: no Participants.
    expect(m.tabs.peek().map((tab) => tab.id)).toEqual(["media", "files", "voice", "links", "settings"])
    expect(m.tabsController.selectedId.peek()).toBe("media")
    stop()
    model!.dispose()
    model = createChatInfoModel({ client: h!.client, chatId: botChat.id, viewerId: me, dialog: signal(undefined), onOpenProfile: () => {}, clock: h!.time })
    const stop2 = effect(() => void model!.header.get())
    await h!.flush()
    expect(model.header.peek().kindLabel).toBe("Bot")
    stop2()
  })

  it("reports tab changes as destination tabs", async () => {
    const tabs: (string | undefined)[] = []
    h = testHarness({ me })
    h.core.setUsers(users)
    h.core.setChat(thread)
    h.client.subscribe({ kind: "chat", chatId: thread.id })
    await h.flush()
    model = createChatInfoModel({
      client: h.client,
      chatId: thread.id,
      viewerId: me,
      dialog: signal(undefined),
      tab: "media",
      onTabChange: (tab) => tabs.push(tab),
      onOpenProfile: () => {},
      clock: h.time,
    })
    expect(model.tabsController.selectedId.peek()).toBe("media")
    model.tabsController.select("settings")
    model.tabsController.select("participants")
    model.tabsController.select("links")
    expect(tabs).toEqual([undefined, "participants", "links"])
  })
})

describe("chat info: participants", () => {
  it("opens a person's profile from the list, by Enter or click", async () => {
    const opened: UserID[] = []
    const { m, stop } = await setup(thread, { opened })
    const items = m.list.items.peek()
    expect(items.map((item) => item.label)).toEqual(["Ada Lovelace", "Helper", "Mo"])
    const ada = rowKey("member", memberRowId({ chatId: thread.id }, uid(2)))
    m.list.setActive(ada)
    expect(m.list.handleKeyDown({ key: "Enter", shiftKey: false, altKey: false, ctrlKey: false, metaKey: false })).toBe(true)
    expect(opened).toEqual([uid(2)])
    m.list.handleKeyDown({ key: "ArrowDown", shiftKey: false, altKey: false, ctrlKey: false, metaKey: false })
    expect(m.list.activeId.peek()).toBe(rowKey("member", memberRowId({ chatId: thread.id }, uid(3))))
    stop()
  })
})

describe("chat info: settings controls", () => {
  it("posts each control's intent and moves the control in the same task", async () => {
    const { t, m, stop } = await setup()
    m.setNotifications("mentions")
    expect(m.settings.peek().notifications).toBe("mentions")
    m.pinSwitch.toggle()
    expect(m.settings.peek().pinned).toBe(true)
    m.setFollowing(true)
    m.setArchived(true)
    m.markUnread()
    expect(m.settings.peek()).toMatchObject({ following: true, archived: true, unread: true })
    expect(t.core.intents.map((entry) => entry.intent)).toEqual([
      { kind: "setDialogNotifications", chatId: thread.id, mode: "mentions" },
      { kind: "setDialogPinned", chatId: thread.id, pinned: true },
      { kind: "setDialogFollow", chatId: thread.id, mode: "following" },
      { kind: "setDialogArchived", chatId: thread.id, archived: true },
      { kind: "markUnread", chatId: thread.id },
    ])
    await t.flush()
    // Confirmed: the dialog row carries the values and the controls have nothing to say.
    expect(m.settings.peek()).toMatchObject({ notifications: "mentions", pinned: true, following: true, archived: true, unread: true })
    expect(m.pinSwitch.pressed.peek()).toBe(true)
    for (const id of ["notifications", "pin", "follow", "archive", "unread"] as const) expect(m.control(id).peek()).toEqual({ kind: "idle" })
    // Back to the default notification mode, and unfollow.
    m.setNotifications("default")
    m.followSwitch.toggle()
    await t.flush()
    expect(t.core.intents.slice(-2).map((entry) => entry.intent)).toEqual([
      { kind: "setDialogNotifications", chatId: thread.id, mode: "default" },
      { kind: "setDialogFollow", chatId: thread.id, mode: "unfollowed" },
    ])
    expect(m.settings.peek()).toMatchObject({ notifications: "default", following: false })
    stop()
  })

  it.each<[IntentMode, string[], Partial<{ pinned: boolean }>]>([
    ["confirm", ["idle", "pending", "idle"], { pinned: true }],
    ["storageFull", ["idle", "pending", "failed:storageFull"], { pinned: false }],
    ["reject", ["idle", "pending", "failed:refused"], { pinned: false }],
    ["unavailable", ["idle", "pending", "failed:unavailable"], { pinned: false }],
    ["offline", ["idle", "pending", "failed:offline"], { pinned: false }],
    ["uncertain", ["idle", "pending", "uncertain:uncertain"], { pinned: true }],
  ])("maps a %s outcome", async (mode, states, after) => {
    const { t, m, stop } = await setup()
    const control = watchControl(m, "pin")
    t.core.intentMode = mode
    m.setPinned(true)
    await t.flush()
    expect(control.seen).toEqual(states)
    expect(m.settings.peek()).toMatchObject(after)
    expect(m.pinSwitch.pressed.peek()).toBe(after.pinned)
    control.stop()
    stop()
  })

  it("says plainly that a change made offline waits to sync, then clears when confirmed", async () => {
    const offline = signal(true)
    const { t, m, stop } = await setup(thread, { offline })
    const control = watchControl(m, "notifications")
    t.core.intentMode = "hold"
    m.setNotifications("none")
    await t.flush()
    expect(m.control("notifications").peek()).toEqual({ kind: "waiting", text: WAITING_TEXT })
    expect(m.settings.peek().notifications).toBe("none")
    offline.set(false)
    t.core.settleHeld("confirmed")
    await t.flush()
    expect(control.seen).toEqual(["idle", "pending", "waiting", "idle"])
    control.stop()
    stop()
  })

  it("shows the server's late refusal and lets the user dismiss it", async () => {
    const { t, m, stop } = await setup()
    t.core.intentMode = "hold"
    m.markUnread()
    await t.flush()
    expect(m.control("unread").peek()).toEqual({ kind: "pending" })
    t.core.settleHeld("rejected", "server")
    await t.flush()
    const state = m.control("unread").peek()
    expect(state.kind === "failed" && state.notice.title).toBe("Couldn't mark the chat as unread")
    m.dismiss("unread")
    expect(m.control("unread").peek()).toEqual({ kind: "idle" })
    stop()
  })

  it("does nothing without a dialog row, and disables the switches", async () => {
    h = testHarness({ me })
    h.core.setChat(thread)
    model = createChatInfoModel({ client: h.client, chatId: thread.id, viewerId: me, dialog: signal(undefined), onOpenProfile: () => {}, clock: h.time })
    const stop = effect(() => void model!.settings.get())
    model.setPinned(true)
    model.markUnread()
    expect(h.core.intents).toEqual([])
    expect(model.pinSwitch.disabled.peek()).toBe(true)
    stop()
  })
})

describe("chat info: copy the chat ID", () => {
  it("copies and says so for two seconds", async () => {
    const copied: string[] = []
    const { t, m, stop } = await setup(thread, { copied })
    m.copyChatId()
    await t.flush()
    expect(copied).toEqual(["10"])
    expect(m.copyState.peek()).toBe("copied")
    t.time.advance(2_000)
    expect(m.copyState.peek()).toBe("idle")
    stop()
  })
})
