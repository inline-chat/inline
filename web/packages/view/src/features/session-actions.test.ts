import { describe, expect, it } from "vitest"
import type { Intent, MessageRow } from "@inline/core-protocol"
import { rowKeyOf, sentMessageRowId } from "@inline/core-protocol"
import type { UserID } from "@inline/ids"
import { message } from "@inline/reactive/testing"
import { allPlatforms, type Platform } from "../commands/platform"
import { reservedComboIds } from "../commands/reserved"
import { AccountSession } from "./account-session"
import type { ActionNotice } from "./intent-outcome"
import { messageCommandIds, type ActionHooks, type MessageTarget } from "./session-actions"
import {
  chatRow,
  cid,
  coreResource,
  dialogRow,
  harness,
  keys,
  mid,
  uid,
  upserts,
  windowResource,
} from "./test-support"

const me = uid(1)
const mac: Platform = { os: "mac", surface: "desktop" }

const sendRow = (clientKey: string, state: MessageRow["state"]): MessageRow => ({
  kind: "message",
  id: sentMessageRowId(cid(5), clientKey),
  chatId: cid(5),
  clientKey,
  fromId: me,
  out: true,
  date: 1_800_000_000,
  text: `send ${clientKey}`,
  state,
})

// Messages of chat 5: someone else's, the viewer's (sent), one sending, one failed.
const theirs = message(5, 1, "from Ada", { fromId: uid(7) })
const own = message(5, 2, "from me", { fromId: me, out: true })
const sending = sendRow("80", "sending")
const failed = sendRow("81", "failed")

const setup = async (options: { platform?: Platform } = {}) => {
  const h = harness()
  const session = new AccountSession({
    userId: me,
    token: "t",
    clock: h.time,
    residentChats: 1,
    platform: options.platform ?? mac,
    connect: () => h.connection(),
  })
  const coreSub = h.sub((query) => query.kind === "core")
  h.endpoint.patch({ resources: [{ sub: coreSub, value: coreResource() }] })
  const lease = session.openChat(cid(5))
  const windowSub = h.sub((query) => query.kind === "chatWindow")
  const rows = [theirs, own, sending, failed]
  h.endpoint.patch({
    rows: upserts(...rows, chatRow(5, { title: "Ops" })),
    lists: [{ sub: windowSub, op: "replace", keys: keys(...rows) }],
    resources: [{ sub: windowSub, value: windowResource() }],
  })
  await h.flush()
  const calls: { hook: string; target?: MessageTarget; value?: unknown }[] = []
  const notices: ActionNotice[] = []
  const hooks: ActionHooks = {
    reply: (target) => calls.push({ hook: "reply", target }),
    edit: (target) => calls.push({ hook: "edit", target }),
    copyText: (text, target) => calls.push({ hook: "copyText", target, value: text }),
    copyLink: (destination) => calls.push({ hook: "copyLink", value: destination }),
    openReactionPicker: (target, anchor) => calls.push({ hook: "react", target, value: anchor }),
    notify: (notice) => notices.push(notice),
  }
  const lastIntent = () => h.endpoint.commands("intent").at(-1)!
  return { ...h, session, lease, coreSub, windowSub, calls, notices, hooks, lastIntent }
}

const ids = (actions: readonly { id: string }[]) => actions.map((action) => action.id)

describe("message commands", () => {
  it("registers the message commands with the Mac's shortcuts, none the browser or OS owns", async () => {
    const s = await setup()
    const registry = s.session.registry
    for (const id of Object.values(messageCommandIds)) expect(registry.get(id)?.scope).toBe("timeline")
    expect(registry.get(messageCommandIds.reply)!.shortcutsFor(mac).map((c) => c.key)).toEqual(["r"])
    expect(registry.get(messageCommandIds.reply)!.shortcutsFor({ os: "mac", surface: "browser" })).toEqual([])
    expect(registry.get(messageCommandIds.delete)!.shortcutsFor(mac)[0]).toMatchObject({ key: "Backspace", meta: true })
    for (const platform of allPlatforms) {
      const reserved = reservedComboIds(platform)
      const offending = [...registry.bindings(platform).keys()].filter((id) => reserved.has(id))
      expect(offending, `${platform.surface}-${platform.os}`).toEqual([])
      expect(registry.conflicts(platform)).toEqual([])
    }
  })

  it("enables each command from the focused message and the hooks attached", async () => {
    const s = await setup()
    const registry = s.session.registry
    const enabled = () =>
      Object.fromEntries(Object.entries(messageCommandIds).map(([name, id]) => [name, registry.isEnabled(id)]))
    const none = { reply: false, edit: false, addReaction: false, copyLink: false, copyText: false, resend: false, cancel: false, delete: false }
    expect(enabled()).toEqual(none)

    // No hooks: only what the chat model does itself.
    s.session.actions.setFocused(own.id)
    expect(enabled()).toEqual({ ...none, delete: true })

    const detach = s.session.attachActions(s.hooks)
    expect(enabled()).toEqual({ ...none, reply: true, edit: true, addReaction: true, copyLink: true, copyText: true, delete: true })
    s.session.actions.setFocused(theirs.id)
    expect(enabled()).toEqual({ ...none, reply: true, addReaction: true, copyLink: true, copyText: true, delete: true })
    s.session.actions.setFocused(sending.id)
    expect(enabled()).toEqual({ ...none, copyText: true, cancel: true, delete: true })
    s.session.actions.setFocused(failed.id)
    expect(enabled()).toEqual({ ...none, copyText: true, resend: true, delete: true })
    s.session.actions.setFocused(undefined)
    expect(enabled()).toEqual(none)
    detach()
  })

  it("Copy Text's shortcut leaves a text selection to the browser", async () => {
    const s = await setup()
    let selected = true
    s.session.attachActions({ ...s.hooks, isTextSelected: () => selected })
    s.session.actions.setFocused(own.id)
    expect(s.session.registry.isEnabled(messageCommandIds.copyText)).toBe(false)
    selected = false
    expect(s.session.registry.run(messageCommandIds.copyText)).toBe(true)
    expect(s.calls.at(-1)).toMatchObject({ hook: "copyText", value: "from me" })
  })

  it("runs the focused message's command: delete posts the intent, reply calls the view", async () => {
    const s = await setup()
    s.session.attachActions(s.hooks)
    s.session.actions.setFocused(own.id)
    s.session.registry.run(messageCommandIds.reply)
    expect(s.calls.at(-1)).toMatchObject({ hook: "reply", target: { chatId: cid(5), messageId: mid(2), rowId: own.id } })
    s.session.registry.run(messageCommandIds.delete)
    expect(s.lastIntent().intent).toEqual({ kind: "deleteMessages", chatId: cid(5), messageIds: [mid(2)] })
    // Cmd+Delete on a message still sending cancels it.
    s.session.actions.setFocused(sending.id)
    s.session.registry.run(messageCommandIds.delete)
    expect(s.lastIntent().intent).toEqual({ kind: "deleteMessages", chatId: cid(5), messageIds: [], clientKeys: ["80"] })
  })

  it("asks before deleting a sent message when the view gives a confirm hook, and never before a cancel", async () => {
    const s = await setup()
    const asked: (() => void)[] = []
    s.session.attachActions({ ...s.hooks, confirmDelete: (_target, proceed) => asked.push(proceed) })
    s.session.actions.setFocused(own.id)
    const before = s.lastIntent()
    // The keyboard command, and the row menu's action, both ask.
    s.session.registry.run(messageCommandIds.delete)
    expect(s.session.actions.delete(s.session.actions.focused.get()!)).toBeUndefined()
    expect(asked).toHaveLength(2)
    expect(s.lastIntent()).toBe(before)
    // Declining is doing nothing; confirming deletes.
    asked[0]!()
    expect(s.lastIntent().intent).toEqual({ kind: "deleteMessages", chatId: cid(5), messageIds: [mid(2)] })
    // A message still sending is cancelled at once.
    s.session.actions.setFocused(sending.id)
    s.session.registry.run(messageCommandIds.delete)
    expect(asked).toHaveLength(2)
    expect(s.lastIntent().intent).toEqual({ kind: "deleteMessages", chatId: cid(5), messageIds: [], clientKeys: ["80"] })
  })

  it("tells the view when an action is refused offline, once", async () => {
    const s = await setup()
    s.session.attachActions(s.hooks)
    s.session.actions.setFocused(own.id)
    s.session.registry.run(messageCommandIds.delete)
    s.endpoint.patch({ settled: [{ tx: s.lastIntent().tx, status: "rejected", reason: "offline" }] })
    await s.flush()
    expect(s.notices).toEqual([expect.objectContaining({ kind: "offline", title: "You're offline" })])
  })

  it("tells the view when an accepted action ends uncertain, and passes a bot's answer on", async () => {
    const s = await setup()
    const answers: unknown[] = []
    s.session.attachActions({ ...s.hooks, answer: (answer) => answers.push(answer) })
    const target = s.session.actions.target(theirs.id)!
    s.session.actions.toggleReaction(target, "👍")
    const react = s.lastIntent().tx
    s.session.actions.invokeAction(target, "go")
    const press = s.lastIntent().tx
    s.endpoint.patch({ settled: [{ tx: react, status: "accepted" }, { tx: press, status: "accepted" }] })
    await s.flush()
    s.endpoint.patch({
      settled: [
        { tx: react, status: "uncertain" },
        { tx: press, status: "confirmed", answer: { kind: "alert", text: "Done" } },
      ],
    })
    await s.flush()
    expect(s.notices).toEqual([expect.objectContaining({ kind: "uncertain", tone: "warning" })])
    expect(answers).toEqual([{ kind: "alert", text: "Done" }])
  })
})

describe("message row actions", () => {
  it("lists the viewer's sent message as the Mac menu does, with shortcut hints", async () => {
    const s = await setup()
    s.session.attachActions(s.hooks)
    const actions = s.session.actions.actionsFor(own.id)
    expect(ids(actions)).toEqual(["reply", "edit", "react", "copyLink", "copyText", "delete"])
    expect(actions.find((a) => a.id === "reply")).toMatchObject({ shortcut: "⌘R", icon: "reply", group: "reply" })
    expect(actions.find((a) => a.id === "edit")?.shortcut).toBe("⌘E")
    expect(actions.find((a) => a.id === "copyText")?.shortcut).toBe("⌘C")
    expect(actions.find((a) => a.id === "delete")).toMatchObject({ shortcut: "⌘⌫", destructive: true, enabled: true })
    expect(actions.filter((a) => a.quick).map((a) => a.id)).toEqual(["react"])
  })

  it("lists someone else's message without Edit", async () => {
    const s = await setup({ platform: { os: "windows", surface: "browser" } })
    s.session.attachActions(s.hooks)
    const actions = s.session.actions.actionsFor(theirs.id)
    expect(ids(actions)).toEqual(["reply", "react", "copyLink", "copyText", "delete"])
    // A browser owns Ctrl+R: no hint for Reply there.
    expect(actions.find((a) => a.id === "reply")?.shortcut).toBeUndefined()
    expect(actions.find((a) => a.id === "delete")?.shortcut).toBe("Ctrl+Backspace")
  })

  it("lists a sending message with Cancel, and a failed one with Resend and Delete", async () => {
    const s = await setup()
    s.session.attachActions(s.hooks)
    expect(ids(s.session.actions.actionsFor(sending.id))).toEqual(["copyText", "cancel"])
    expect(ids(s.session.actions.actionsFor(failed.id))).toEqual(["copyText", "resend", "delete"])
    s.session.actions.actionsFor(failed.id).find((a) => a.id === "resend")!.run({ rowId: failed.id, via: "menu" })
    expect(s.lastIntent().intent).toEqual({ kind: "retrySend", chatId: cid(5), clientKey: "81" })
    s.session.actions.actionsFor(sending.id).find((a) => a.id === "cancel")!.run({ rowId: sending.id, via: "menu" })
    expect(s.lastIntent().intent).toMatchObject({ kind: "deleteMessages", clientKeys: ["80"] })
  })

  it("leaves out what has no hook, and passes the quick action's anchor to the picker", async () => {
    const s = await setup()
    expect(ids(s.session.actions.actionsFor(own.id))).toEqual(["delete"])
    s.session.attachActions(s.hooks)
    const anchor = { x: 1, y: 2, width: 3, height: 4 }
    s.session.actions.actionsFor(own.id).find((a) => a.id === "react")!.run({ rowId: own.id, via: "quick", anchor })
    expect(s.calls.at(-1)).toMatchObject({ hook: "react", value: anchor })
    expect(s.session.actions.actionsFor("5:999")).toEqual([])
  })

  it("disables what needs the chat model once the chat is not resident", async () => {
    const s = await setup()
    s.session.attachActions(s.hooks)
    s.lease.release()
    s.session.openChat(cid(6)).release()
    expect(s.session.chats.peek(cid(5))).toBeUndefined()
    // The rows are still in the store until the core removes them.
    const actions = s.session.actions.actionsFor(own.id)
    expect(actions.find((a) => a.id === "delete")?.enabled).toBe(false)
    expect(actions.find((a) => a.id === "reply")?.enabled).toBe(true)
  })
})

describe("sidebar row actions", () => {
  const item = (s: Awaited<ReturnType<typeof setup>>, extra: Parameters<typeof dialogRow>[1]) => {
    const dialog = dialogRow(5, extra)
    s.endpoint.patch({ rows: upserts(dialog) })
    return s.session.sidebar.item(rowKeyOf(dialog))
  }

  it("builds the basic menu and maps each entry to its dialog intent", async () => {
    const s = await setup()
    s.session.attachActions(s.hooks)
    const signal = item(s, { unreadCount: 2 })
    await s.flush()
    const actions = s.session.actions.sidebarActionsFor(signal.peek()!)
    expect(actions.map((a) => a.id)).toEqual(["pin", "read", "close", "archive", "settings", "notifications", "follow", "link", "copyLink"])
    const run = (id: string) => {
      const action = actions.find((a) => a.id === id)!
      if (action.kind !== "separator" && action.kind !== "submenu") action.run()
      return s.lastIntent().intent
    }
    expect(actions.find((a) => a.id === "read")).toMatchObject({ label: "Mark Read" })
    expect(run("pin")).toEqual({ kind: "setDialogPinned", chatId: cid(5), pinned: true })
    expect(run("read")).toEqual({ kind: "readAll", chatId: cid(5) })
    expect(run("close")).toEqual({ kind: "setDialogOpen", chatId: cid(5), open: false })
    expect(run("archive")).toEqual({ kind: "setDialogArchived", chatId: cid(5), archived: true })
    run("copyLink")
    expect(s.calls.at(-1)).toEqual({ hook: "copyLink", value: { kind: "chat", chatId: cid(5) } })
  })

  it("offers the dialog's notification modes (the current one checked) and Follow or Unfollow for a thread, never for a direct message", async () => {
    const s = await setup()
    const thread = item(s, { notificationMode: "mentions", followMode: "following" })
    await s.flush()
    const actions = s.session.actions.sidebarActionsFor(thread.peek()!)
    const notifications = actions.find((a) => a.id === "notifications")
    if (notifications?.kind !== "submenu") throw new Error("no Notifications submenu")
    expect(notifications.label).toBe("Notifications")
    expect(notifications.actions.map((a) => (a.kind === "radio" ? [a.label, a.checked] : a.id))).toEqual([
      ["Default", false],
      ["All", false],
      ["Mentions", true],
      ["None", false],
    ])
    for (const [index, mode] of (["default", "all", "mentions", "none"] as const).entries()) {
      const choice = notifications.actions[index]!
      if (choice.kind === "radio") choice.run()
      expect(s.lastIntent().intent).toEqual({ kind: "setDialogNotifications", chatId: cid(5), mode })
    }
    const follow = actions.find((a) => a.id === "follow")
    expect(follow).toMatchObject({ label: "Unfollow Thread" })
    if (follow && (follow.kind === undefined || follow.kind === "action")) follow.run()
    expect(s.lastIntent().intent).toEqual({ kind: "setDialogFollow", chatId: cid(5), mode: "unfollowed" })

    // No mode: Default is checked; not followed: Follow Thread.
    const plain = item(s, {})
    await s.flush()
    const fresh = s.session.actions.sidebarActionsFor(plain.peek()!)
    const freshNotifications = fresh.find((a) => a.id === "notifications")
    expect(freshNotifications?.kind === "submenu" && freshNotifications.actions.find((a) => a.kind === "radio" && a.checked)?.id).toBe("notifications-default")
    const followNow = fresh.find((a) => a.id === "follow")
    expect(followNow).toMatchObject({ label: "Follow Thread" })
    if (followNow && (followNow.kind === undefined || followNow.kind === "action")) followNow.run()
    expect(s.lastIntent().intent).toEqual({ kind: "setDialogFollow", chatId: cid(5), mode: "following" })

    // A direct message has the modes but nothing to follow.
    const direct = item(s, { peerUserId: uid(9) })
    await s.flush()
    const dm = s.session.actions.sidebarActionsFor(direct.peek()!)
    expect(dm.some((a) => a.id === "notifications")).toBe(true)
    expect(dm.some((a) => a.id === "follow")).toBe(false)
  })

  it("offers Mark Unread, Unpin and Unarchive by state, and Close or Keep for a temporary row", async () => {
    const s = await setup()
    const read = item(s, { pinned: true, archived: true })
    await s.flush()
    const labels = s.session.actions.sidebarActionsFor(read.peek()!).map((a) => (a.kind === "separator" ? "-" : a.label))
    expect(labels).toEqual(["Unpin", "Mark Unread", "Close from Sidebar", "Unarchive", "-", "Notifications", "Follow Thread"])
    const markUnread = s.session.actions.sidebarActionsFor(read.peek()!).find((a) => a.id === "read")!
    if (markUnread.kind === undefined || markUnread.kind === "action") markUnread.run()
    expect(s.lastIntent().intent).toEqual({ kind: "markUnread", chatId: cid(5) })

    const temporary = item(s, { open: false })
    await s.flush()
    const actions = s.session.actions.sidebarActionsFor(temporary.peek()!)
    expect(actions.map((a) => a.id)).toEqual(["close", "temporary", "keep"])
    const keep = actions.find((a) => a.id === "keep")!
    if (keep.kind === undefined || keep.kind === "action") keep.run()
    expect(s.lastIntent().intent).toEqual({ kind: "setDialogOpen", chatId: cid(5), open: true })
  })

  it("reports a refused dialog intent", async () => {
    const s = await setup()
    s.session.attachActions(s.hooks)
    const signal = item(s, {})
    await s.flush()
    const pin = s.session.actions.sidebarActionsFor(signal.peek()!).find((a) => a.id === "pin")!
    if (pin.kind === undefined || pin.kind === "action") pin.run()
    s.endpoint.patch({ settled: [{ tx: s.lastIntent().tx, status: "rejected", reason: "storageFull" }] })
    await s.flush()
    expect(s.notices).toEqual([expect.objectContaining({ kind: "storageFull", text: "Couldn't pin the chat because storage on this device is full." })])
  })
})

describe("session health", () => {
  it("tells offline from connecting from a stalled sync, and retries sync", async () => {
    const s = await setup()
    const set = (extra: Parameters<typeof coreResource>[0]) =>
      s.endpoint.patch({ resources: [{ sub: s.coreSub, value: coreResource(extra) }] })
    expect(s.session.health.peek()).toEqual({ kind: "ok" })

    set({ connection: "waitingForNetwork" })
    await s.flush()
    // After a connection, the rule 15 delay applies as it does to `connection`.
    expect(s.session.health.peek()).toEqual({ kind: "ok" })
    s.time.advance(1_000)
    expect(s.session.health.peek()).toEqual({ kind: "offline" })
    // While shown, a change shows at once.
    set({ connection: "connecting" })
    await s.flush()
    expect(s.session.health.peek()).toEqual({ kind: "connecting" })

    const stall = { scope: "chat" as const, chatId: cid(5), reason: "retryLimit" as const }
    set({ stalledSync: [stall] })
    await s.flush()
    expect(s.session.health.peek()).toEqual({ kind: "syncStalled", stalls: [stall], retryable: true })
    expect(s.session.stalledSync.peek()).toEqual([stall])

    const retry = s.session.retrySync()
    expect(s.lastIntent().intent).toEqual({ kind: "retrySync" } satisfies Intent)
    s.endpoint.patch({
      resources: [{ sub: s.coreSub, value: coreResource() }],
      settled: [{ tx: retry.tx, status: "confirmed" }],
    })
    await s.flush()
    expect(await retry).toEqual({ status: "accepted", tx: retry.tx })
    expect(await retry.outcome).toEqual({ status: "confirmed", tx: retry.tx })
    expect(s.session.health.peek()).toEqual({ kind: "ok" })

    set({ stalledSync: [{ scope: "account", reason: "repairUnavailable" }] })
    await s.flush()
    expect(s.session.health.peek()).toMatchObject({ kind: "syncStalled", retryable: false })
    set({ connection: "sessionRevoked" })
    await s.flush()
    expect(s.session.health.peek()).toEqual({ kind: "refused" })
  })
})

describe("chat dialogs and the window's trim through the session", () => {
  it("finds a chat's dialog through the chat row's `dialogId`, archived or not, and follows both rows", async () => {
    const s = await setup()
    const dialog = s.session.dialogFor(cid(5))
    expect(dialog.peek()).toBeUndefined()
    // An archived dialog, which no sidebar list of the session carries; the chat row names it.
    s.endpoint.patch({ rows: upserts(dialogRow(5, { archived: true, unreadCount: 3, readMaxId: mid(1) })) })
    await s.flush()
    expect(dialog.peek()).toMatchObject({ archived: true, unreadCount: 3 })
    expect(s.session.dialogFor(cid(5))).toBe(dialog)
    // A chat row that names no dialog (or another one) has none here: no second index guesses.
    s.endpoint.patch({ rows: upserts(chatRow(5, { title: "Ops", dialogId: undefined })) })
    await s.flush()
    expect(dialog.peek()).toBeUndefined()
    s.endpoint.patch({ rows: upserts(chatRow(5, { title: "Ops" })) })
    await s.flush()
    expect(dialog.peek()).toMatchObject({ archived: true, unreadCount: 3 })
    expect(s.lease.model.readState.peek()).toEqual({ unreadCount: 3, readMaxId: mid(1) })
  })

  it("sends the trim command on the chat window's subscription", async () => {
    const s = await setup()
    expect(s.lease.model.trimWindow({ from: mid(2), to: mid(2) })).toBe(true)
    expect(s.endpoint.commands("trimWindow")).toEqual([{ kind: "trimWindow", sub: s.windowSub, keep: { from: mid(2), to: mid(2) } }])
  })
})

describe("sidebar readiness through the session", () => {
  it("is ready once the core answers the visible mode", async () => {
    const h = harness()
    const session = new AccountSession({ userId: me as UserID, token: "t", clock: h.time, connect: () => h.connection() })
    expect(session.sidebar.ready.peek()).toBe(false)
    const inbox = h.sub((query) => query.kind === "sidebar" && query.mode === "inbox")
    h.endpoint.patch({ lists: [{ sub: inbox, op: "replace", keys: [] }] })
    await h.flush()
    expect(session.sidebar.ready.peek()).toBe(true)
    session.dispose()
  })
})
