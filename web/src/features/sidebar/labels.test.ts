import type { RowKey } from "@inline/core-protocol"
import type { ChatID, DialogID } from "@inline/ids"
import type { SidebarItem } from "@inline/view/features"
import { describe, expect, it } from "vitest"
import { basicActions, toMenuEntries, type SidebarAction } from "./actions"
import { avatarCacheSize, avatarFace } from "./avatar"
import { badgeText, emptyText, rowLabel, unreadBelowValue } from "./labels"

const item = (extra: Partial<SidebarItem> = {}): SidebarItem => ({
  key: "dialog:1" as RowKey,
  dialogId: "1" as DialogID,
  chatId: "1" as ChatID,
  title: "Launch",
  avatar: { kind: "chat", chatId: "1" as ChatID, seed: "Launch" },
  preview: { kind: "none" },
  unreadCount: 0,
  unreadMark: false,
  hasUnread: false,
  prominent: false,
  pinned: false,
  selected: false,
  ...extra,
})

describe("labels", () => {
  it("caps badges at 99+", () => {
    expect(badgeText(7)).toBe("7")
    expect(badgeText(99)).toBe("99")
    expect(badgeText(100)).toBe("99+")
    expect(unreadBelowValue(1)).toBe("1 unread chat below")
    expect(unreadBelowValue(150)).toBe("99+ unread chats below")
  })

  it("names a row with what it shows, draft before message", () => {
    expect(rowLabel(item())).toBe("Launch")
    expect(rowLabel(item({ pinned: true, unreadCount: 3, hasUnread: true, preview: { kind: "draft", text: "half" } }))).toBe(
      "Launch, pinned, 3 unread, Draft: half",
    )
    expect(rowLabel(item({ unreadMark: true, hasUnread: true, preview: { kind: "message", text: "hi", outgoing: true } }))).toBe(
      "Launch, marked unread, You: hi",
    )
    // Someone composing replaces the preview in the name, as it does on screen.
    expect(rowLabel(item({ unreadCount: 2, hasUnread: true, preview: { kind: "draft", text: "half" } }), "Ada is typing")).toBe(
      "Launch, 2 unread, Ada is typing",
    )
  })

  it("has empty text per mode", () => {
    expect(emptyText("inbox").title).toBe("No open chats")
    expect(emptyText("all").title).toBe("No chats yet")
  })
})

describe("actions", () => {
  const run = () => {}

  it("maps actions to menu entries, dropping stray separators", () => {
    const actions: SidebarAction[] = [
      { kind: "separator", id: "s0" },
      { id: "pin", label: "Pin", shortcut: "⌘⇧P", run },
      { kind: "separator", id: "s1" },
      { kind: "separator", id: "s2" },
      { id: "archive", label: "Archive", enabled: false, destructive: true, run },
      { kind: "separator", id: "s3" },
    ]
    expect(toMenuEntries(actions)).toEqual([
      { type: "item", id: "pin", label: "Pin", shortcut: "⌘⇧P", onSelect: run },
      { type: "separator", id: "s1" },
      { type: "item", id: "archive", label: "Archive", disabled: true, destructive: true, onSelect: run },
    ])
  })

  it("builds the Mac's basic menu from the handlers given", () => {
    const calls: string[] = []
    const handlers = {
      togglePin: () => calls.push("pin"),
      markRead: () => calls.push("read"),
      markUnread: () => calls.push("unread"),
      toggleArchive: () => calls.push("archive"),
      close: () => calls.push("close"),
      keep: () => calls.push("keep"),
      copyLink: () => calls.push("copy"),
    }
    const unread = basicActions(item({ hasUnread: true, pinned: true }), handlers)
    expect(unread.map((a) => (a.kind === "separator" ? "—" : a.label))).toEqual([
      "Unpin",
      "Mark Read",
      "Close from Sidebar",
      "Archive",
      "—",
      "Copy Link",
    ])
    const read = basicActions(item(), { ...handlers, isArchived: () => true })
    expect(read.map((a) => (a.kind === "separator" ? "—" : a.label))).toEqual([
      "Pin",
      "Mark Unread",
      "Close from Sidebar",
      "Unarchive",
      "—",
      "Copy Link",
    ])
    const temporary = basicActions(item(), { ...handlers, isTemporary: () => true })
    expect(temporary.map((a) => (a.kind === "separator" ? "—" : a.label))).toEqual([
      "Close from Sidebar",
      "—",
      "Keep in Sidebar",
      "—",
      "Copy Link",
    ])
    for (const action of unread) if (action.kind !== "separator" && action.kind !== "submenu") action.run()
    expect(calls).toEqual(["pin", "read", "close", "archive", "copy"])
    expect(basicActions(item(), {})).toEqual([])
  })

  it("adds Notifications and Follow Thread after the chat's state, before Copy Link (Mac toolbar settings)", () => {
    const calls: string[] = []
    const handlers = {
      togglePin: () => calls.push("pin"),
      copyLink: () => calls.push("copy"),
      setNotifications: (_: SidebarItem, mode: string) => calls.push(`notify:${mode}`),
      setFollow: (_: SidebarItem, mode: string) => calls.push(`follow:${mode}`),
    }
    const labels = (actions: readonly SidebarAction[]) => actions.map((a) => (a.kind === "separator" ? "—" : a.label))
    const thread = basicActions(item({ notificationMode: "mentions" }), handlers)
    expect(labels(thread)).toEqual(["Pin", "—", "Notifications", "Follow Thread", "—", "Copy Link"])
    const submenu = thread.find((action) => action.kind === "submenu")
    if (submenu?.kind !== "submenu") throw new Error("no submenu")
    expect(submenu.actions.map((a) => (a.kind === "radio" ? [a.label, a.checked] : a.kind))).toEqual([
      ["Default", false],
      ["All", false],
      ["Mentions", true],
      ["None", false],
    ])
    const none = submenu.actions[3]
    if (none?.kind === "radio") none.run()
    const follow = thread.find((action) => action.kind === undefined && action.id === "follow")
    if (follow && follow.kind === undefined) follow.run()
    expect(calls).toEqual(["notify:none", "follow:following"])

    // A followed thread offers Unfollow; no mode set means Default.
    const followed = basicActions(item({ followMode: "following" }), handlers)
    expect(labels(followed)).toContain("Unfollow Thread")
    const defaults = toMenuEntries(followed).find((entry) => entry.type === "submenu")
    expect(defaults?.type === "submenu" && typeof defaults.items !== "function" && defaults.items[0]).toMatchObject({
      type: "radio",
      label: "Default",
      checked: true,
    })

    // A direct message has no follow; a temporary row has neither.
    expect(labels(basicActions(item({ peerUserId: "7" as never }), handlers))).not.toContain("Follow Thread")
    expect(labels(basicActions(item(), { ...handlers, isTemporary: () => true }))).not.toContain("Notifications")
  })

  it("maps radio choices and submenus to the kit's entries, dropping an empty submenu", () => {
    const run = () => {}
    expect(
      toMenuEntries([
        { kind: "submenu", id: "empty", label: "Nothing", actions: [] },
        { kind: "submenu", id: "n", label: "Notifications", actions: [{ kind: "radio", id: "all", label: "All", checked: true, run }] },
        { id: "mute", label: "Mute", shortcut: "⌥⌘M", keyshortcuts: "Alt+Meta+M", run },
      ]),
    ).toEqual([
      { type: "submenu", id: "n", label: "Notifications", items: [{ type: "radio", id: "all", label: "All", checked: true, onSelect: run }] },
      { type: "item", id: "mute", label: "Mute", shortcut: "⌥⌘M", keyshortcuts: "Alt+Meta+M", onSelect: run },
    ])
  })
})

describe("avatarFace", () => {
  it("caches initials and colors per name and seed", () => {
    const before = avatarCacheSize()
    const a = avatarFace("Ada Lovelace", "Ada Lovelace")
    expect(a.initials).toBe("AL")
    expect(avatarFace("Ada Lovelace", "Ada Lovelace")).toBe(a)
    expect(avatarCacheSize()).toBe(before + 1)
    expect(avatarFace("ليلى حسن", "ليلى حسن").initials).toBe("لح")
  })
})
