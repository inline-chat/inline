/**
 * The notification and badge controllers over a real `AccountSession`, a
 * scripted core and the fake platform, on manual clocks.
 */

import { rowKeyOf } from "@inline/core-protocol"
import { userGesture, type UserGesture } from "@inline/platform"
import { signal } from "@inline/reactive"
import { describe, expect, it } from "vitest"
import { PROMPT_DISMISSED_KEY } from "./permission"
import { createViewingTracker, type ViewingChannel } from "./viewing"
import {
  chatRow,
  cid,
  dialogRow,
  did,
  ME,
  message,
  mid,
  setup,
  uid,
  userRow,
  windowResource,
  type Context,
} from "./test-support"

const ann = userRow(1, "Ann")

/** A direct message with Ann (chat 5) in the sidebar, its window open with message 50. */
const dmWithAnn = async (c: Context, extra: { readMaxId?: number } = {}) => {
  await c.sidebar([
    ann,
    chatRow(5, { peerUserId: uid(1) }),
    dialogRow(5, { peerUserId: uid(1), unreadCount: 1, ...(extra.readMaxId ? { readMaxId: mid(extra.readMaxId) } : {}) }),
  ])
  return c.openChat(5, [message(5, 50)])
}

const tag = (chat: number, id: number) => `chat_${chat}_message_${id}`

/** An in-memory `BroadcastChannel`: every other member gets each message. */
const channelHub = () => {
  const members = new Set<{ listeners: Set<(event: { data: unknown }) => void> }>()
  return (): ViewingChannel & { close(): void } => {
    const member = { listeners: new Set<(event: { data: unknown }) => void>() }
    members.add(member)
    return {
      postMessage(data) {
        for (const other of members) if (other !== member) for (const listener of other.listeners) listener({ data })
      },
      addEventListener: (_type, listener) => void member.listeners.add(listener),
      removeEventListener: (_type, listener) => void member.listeners.delete(listener),
      close: () => void members.delete(member),
    }
  }
}

const memoryStorage = () => {
  const data = new Map<string, string>()
  return { data, getItem: (key: string) => data.get(key) ?? null, setItem: (key: string, value: string) => void data.set(key, value) }
}

describe("badge", () => {
  it("follows the prominent unread count, increases after 500 ms, decreases at once, clears on dispose", async () => {
    const c = setup()
    const attachment = c.attach()
    await c.sidebar([dialogRow(1, { peerUserId: uid(1), unreadCount: 2 }), dialogRow(2, { unreadCount: 3 })])
    // The thread's unread is muted; only the DM counts.
    expect(c.session.badgeCount.peek()).toBe(1)
    c.fake.clock.advance(499)
    expect(c.fake.badge.applied).toEqual([])
    c.fake.clock.advance(1)
    expect(c.fake.badge.applied).toEqual([1])

    await c.sidebar([dialogRow(1, { peerUserId: uid(1), unreadCount: 2 }), dialogRow(3, { peerUserId: uid(3), unreadCount: 1 })])
    c.fake.clock.advance(500)
    expect(c.fake.badge.applied).toEqual([1, 2])

    await c.sidebar([dialogRow(1, { peerUserId: uid(1), unreadCount: 0 }), dialogRow(3, { peerUserId: uid(3), unreadCount: 1 })])
    expect(c.fake.badge.applied).toEqual([1, 2, 1])

    attachment()
    expect(c.fake.badge.applied).toEqual([1, 2, 1, 0])
    expect(c.fake.platform.badge.count.peek()).toBe(0)
  })

  it("shows the count at once on sign-in and when the setting is turned back on", async () => {
    const c = setup()
    await c.sidebar([dialogRow(1, { peerUserId: uid(1), unreadCount: 1 })])
    const enabled = signal(true)
    c.attach({ badgeEnabled: enabled })
    expect(c.fake.badge.applied).toEqual([1])
    enabled.set(false)
    expect(c.fake.badge.applied).toEqual([1, 0])
    enabled.set(true)
    expect(c.fake.badge.applied).toEqual([1, 0, 1])
  })
})

describe("message notifications", () => {
  it("shows one notification for a new incoming message in a chat that is not being viewed", async () => {
    const c = setup()
    const sounds: unknown[] = []
    c.attach({ onSound: (event) => sounds.push(event) })
    await dmWithAnn(c)
    expect(c.fake.notifications.shown).toEqual([])

    await c.arrive(5, message(5, 51, "Lunch\n  at   noon?"))
    expect(c.fake.notifications.shown).toEqual([
      {
        tag: tag(5, 51),
        title: "Ann",
        body: "Lunch at noon?",
        group: "chat_5",
        silent: false,
        urgent: false,
        data: { kind: "message", chatId: "5", messageId: "51", userId: ME },
      },
    ])
    expect(sounds).toEqual([{ chatId: cid(5), messageId: mid(51), urgent: false }])
    expect(c.attachment?.controller.openTags()).toEqual([tag(5, 51)])
  })

  it("titles a thread message with the thread and its space, and puts the sender in the body", async () => {
    const c = setup()
    c.attach()
    await c.sidebar([ann, { kind: "space", id: "7", name: "Acme" } as never, chatRow(6, { title: "Design", spaceId: "7" as never }), dialogRow(6)])
    await c.openChat(6, [])
    await c.arrive(6, message(6, 1, "x".repeat(400)))
    const shown = c.fake.notifications.shown[0]
    expect(shown?.title).toBe("Design (Acme)")
    expect(shown?.body?.startsWith("Ann: xxx")).toBe(true)
    expect(Array.from(shown?.body ?? "").length).toBeLessThanOrEqual(240)
  })

  it("shows nothing in a follower context, and notifies once this context leads", async () => {
    const c = setup({ role: "follower" })
    c.attach()
    await dmWithAnn(c)
    await c.arrive(5, message(5, 51))
    expect(c.fake.notifications.shown).toEqual([])

    c.role.set("leader")
    await c.arrive(5, message(5, 52))
    expect(c.fake.notifications.shown.map((n) => n.tag)).toEqual([tag(5, 52)])
  })

  it("shows nothing while the chat is viewed in a visible, focused window, and notifies once focus leaves", async () => {
    const c = setup()
    c.attach()
    await dmWithAnn(c)
    c.session.workspace.open({ kind: "chat", chatId: cid(5) })
    await c.arrive(5, message(5, 51))
    expect(c.fake.notifications.shown).toEqual([])

    c.fake.lifecycle.setFocused(false)
    await c.arrive(5, message(5, 52))
    expect(c.fake.notifications.shown.map((n) => n.tag)).toEqual([tag(5, 52)])

    // Another chat on screen does not suppress this one.
    c.fake.lifecycle.setFocused(true)
    c.session.workspace.open({ kind: "chat", chatId: cid(8) })
    await c.arrive(5, message(5, 53))
    expect(c.fake.notifications.shown.map((n) => n.tag)).toEqual([tag(5, 52), tag(5, 53)])
  })

  it("never notifies for rows loaded by opening a chat or paging older or newer history", async () => {
    const c = setup()
    c.attach()
    await c.sidebar([ann, chatRow(5, { peerUserId: uid(1) }), dialogRow(5, { peerUserId: uid(1) })])
    // Opening: every row is fresh (under 2 minutes old) and unread.
    const window = await c.openChat(5, [message(5, 60), message(5, 61)])
    // Paging older.
    const older = [message(5, 40), message(5, 41)]
    await c.deliver({
      rows: older,
      lists: [{ sub: window.sub, keys: [...older.map(rowKeyOf), ...c.keys(window.sub)] }],
      windows: [{ sub: window.sub, value: windowResource({ hasOlder: true }) }],
    })
    // Jumping to a message, then back to the latest page, which brings two newer messages.
    const around = [message(5, 20), message(5, 21)]
    await c.deliver({
      rows: around,
      lists: [{ sub: window.sub, keys: around.map(rowKeyOf) }],
      windows: [{ sub: window.sub, value: windowResource({ atLatest: false, hasNewer: true }) }],
    })
    const latest = [message(5, 61), message(5, 62), message(5, 63)]
    await c.deliver({
      rows: latest,
      lists: [{ sub: window.sub, keys: latest.map(rowKeyOf) }],
      windows: [{ sub: window.sub, value: windowResource() }],
    })
    // A chat opened away from the latest page, paged newer up to it.
    await c.sidebar([ann, chatRow(5, { peerUserId: uid(1) }), dialogRow(5, { peerUserId: uid(1) }), dialogRow(6), chatRow(6, { title: "T" })])
    const other = await c.openChat(6, [message(6, 10)], { atLatest: false, hasNewer: true })
    const newer = [message(6, 10), message(6, 11), message(6, 12)]
    await c.deliver({
      rows: newer,
      lists: [{ sub: other.sub, keys: newer.map(rowKeyOf) }],
      windows: [{ sub: other.sub, value: windowResource() }],
    })
    expect(c.fake.notifications.shown).toEqual([])

    // A live arrival after all of that still notifies.
    await c.arrive(5, message(5, 64))
    await c.arrive(6, message(6, 13))
    expect(c.fake.notifications.shown.map((n) => n.tag)).toEqual([tag(5, 64), tag(6, 13)])
  })

  it("never notifies for the user's own messages, sent here or elsewhere", async () => {
    const c = setup()
    c.attach()
    await dmWithAnn(c)
    const model = c.session.chats.peek(cid(5))
    void model?.send("from this tab")
    await c.flush()
    await c.arrive(5, message(5, 51, "from my phone", { out: true, fromId: ME }))
    expect(c.fake.notifications.shown).toEqual([])
  })

  it("does not notify for a message older than two minutes or one already read", async () => {
    const c = setup()
    c.attach()
    await dmWithAnn(c, { readMaxId: 52 })
    // Delivered late: the message date is 3 minutes before now.
    await c.arrive(5, message(5, 51, "late", { date: Math.floor(1_700_000_100 - 180) }))
    c.fake.clock.advance(0)
    expect(c.fake.notifications.shown).toEqual([])
    // Read on another device before it reached this one.
    await c.arrive(5, message(5, 52))
    expect(c.fake.notifications.shown).toEqual([])
    await c.arrive(5, message(5, 53))
    expect(c.fake.notifications.shown.map((n) => n.tag)).toEqual([tag(5, 53)])
  })

  it("opens the chat at the message on click", async () => {
    const c = setup()
    c.attach()
    await dmWithAnn(c)
    await c.arrive(5, message(5, 51))
    c.fake.notifications.click(tag(5, 51))
    expect(c.session.workspace.focusedDestination.peek()).toEqual({ kind: "message", chatId: cid(5), messageId: mid(51) })
    expect(c.attachment?.controller.openTags()).toEqual([])
  })

  it("closes notifications the user has read, up to the read frontier", async () => {
    const c = setup()
    c.attach()
    await dmWithAnn(c)
    await c.arrive(5, message(5, 51))
    await c.arrive(5, message(5, 52))
    expect(c.fake.notifications.openTags()).toEqual([tag(5, 51), tag(5, 52)])

    await c.sidebar([ann, chatRow(5, { peerUserId: uid(1) }), dialogRow(5, { peerUserId: uid(1), readMaxId: mid(51) })])
    expect(c.fake.notifications.openTags()).toEqual([tag(5, 52)])
    expect(c.fake.notifications.closedTags).toEqual([tag(5, 51)])

    await c.sidebar([ann, chatRow(5, { peerUserId: uid(1) }), dialogRow(5, { peerUserId: uid(1), readMaxId: mid(52) })])
    expect(c.fake.notifications.openTags()).toEqual([])
  })

  it("leaves a shown notification as it is when the message is edited, as the Mac does", async () => {
    const c = setup()
    c.attach()
    await dmWithAnn(c)
    await c.arrive(5, message(5, 51, "first"))
    await c.deliver({ rows: [message(5, 51, "edited", { editDate: 1_700_000_090 })] })
    expect(c.fake.notifications.shown.map((n) => n.body)).toEqual(["first"])
    expect(c.fake.notifications.openTags()).toEqual([tag(5, 51)])
  })

  it("notifies an urgent nudge even while the chat is viewed", async () => {
    const c = setup()
    c.attach()
    await dmWithAnn(c)
    c.session.workspace.open({ kind: "chat", chatId: cid(5) })
    await c.arrive(5, message(5, 51, "\u{1F6A8}", { media: { kind: "nudge" } }))
    expect(c.fake.notifications.shown.map((n) => [n.body, n.urgent])).toEqual([["\u{1F6A8} Urgent nudge", true]])
  })

  it("does not notify while another tab of the account shows the chat in a focused window", async () => {
    const hub = channelHub()
    const c = setup()
    c.attach({ channel: hub(), contextId: "leader" })
    await dmWithAnn(c)
    c.fake.lifecycle.setVisible(false)

    // A follower tab, visible and focused, showing chat 5.
    const panes = signal(c.session.workspace.panes.peek())
    const visible = signal(true)
    const focused = signal(true)
    const follower = createViewingTracker({ panes, visible, focused, channel: hub(), contextId: "follower" })
    c.session.workspace.open({ kind: "chat", chatId: cid(5) })
    panes.set(c.session.workspace.panes.peek())

    await c.arrive(5, message(5, 51))
    expect(c.fake.notifications.shown).toEqual([])

    focused.set(false)
    await c.arrive(5, message(5, 52))
    expect(c.fake.notifications.shown.map((n) => n.tag)).toEqual([tag(5, 52)])
    follower.dispose()
  })

  it("closes its notifications and unsubscribes the feed on dispose", async () => {
    const c = setup()
    const attachment = c.attach()
    await dmWithAnn(c)
    const feed = c.feedSub()
    await c.arrive(5, message(5, 51))
    attachment()
    expect(c.fake.notifications.openTags()).toEqual([])
    expect(c.endpoint.commands("unsubscribe").map((command) => command.sub)).toContain(feed)
    expect(() => c.feedSub()).toThrow()
  })

  it("notifies for a chat that has no subscribed window anywhere, with the rows the feed brings", async () => {
    const c = setup()
    c.attach()
    // Not in any window, not open in the sidebar: the feed carries chat, dialog and sender.
    expect(c.session.chats.resident.peek()).toEqual([])
    await c.arrive(5, message(5, 51, "are you there?"), [
      ann,
      chatRow(5, { peerUserId: uid(1) }),
      dialogRow(5, { peerUserId: uid(1), open: false }),
    ])
    expect(c.fake.notifications.shown.map((n) => [n.tag, n.title, n.body])).toEqual([[tag(5, 51), "Ann", "are you there?"]])

    // Read elsewhere: the dialog the feed brought closes it, without a sidebar row.
    await c.deliver({ rows: [dialogRow(5, { peerUserId: uid(1), open: false, readMaxId: mid(51) })] })
    expect(c.fake.notifications.openTags()).toEqual([])
  })

  it("does not notify a silent message", async () => {
    const c = setup()
    c.attach()
    await c.arrive(5, message(5, 51, "shh", { silent: true }), [ann, chatRow(5, { peerUserId: uid(1) }), dialogRow(5, { peerUserId: uid(1) })])
    expect(c.fake.notifications.shown).toEqual([])
  })

  it("follows the chat's notification mode: a mentions-only chat notifies for a mention and nothing else", async () => {
    const c = setup()
    c.attach()
    const rows = [ann, chatRow(6, { title: "Design" }), dialogRow(6, { notificationMode: "mentions" })]
    await c.arrive(6, message(6, 1, "status update"), rows)
    expect(c.fake.notifications.shown).toEqual([])
    await c.arrive(6, message(6, 2, "@team look", { mentioned: true }))
    expect(c.fake.notifications.shown.map((n) => n.tag)).toEqual([tag(6, 2)])

    // A chat set to none never notifies; the dialog's mode beats the account default.
    await c.arrive(7, message(7, 1, "x", { mentioned: true }), [chatRow(7, { title: "Muted" }), dialogRow(7, { notificationMode: "none" })])
    expect(c.fake.notifications.shown.map((n) => n.tag)).toEqual([tag(6, 2)])
  })

  it("finds the chat's dialog through ChatRow.dialogId, whatever the dialog's own ID", async () => {
    const c = setup()
    c.attach()
    // Dialog IDs are the server's own: chat 8's dialog is 80. Muted, so it must be found to stay quiet.
    const muted = [ann, chatRow(8, { title: "Ops", dialogId: did(80) }), dialogRow(80, { chatId: cid(8), notificationMode: "none" })]
    await c.arrive(8, message(8, 1, "x", { mentioned: true }), muted)
    expect(c.fake.notifications.shown).toEqual([])
    // A stray dialog row naming chat 9, seen last, is not its dialog: `dialogId` decides, not the last row seen.
    const team = [ann, chatRow(9, { title: "Team", dialogId: did(90) }), dialogRow(90, { chatId: cid(9) }), dialogRow(9, { notificationMode: "none" })]
    await c.arrive(9, message(9, 1, "hi"), team)
    expect(c.fake.notifications.shown.map((n) => n.tag)).toEqual([tag(9, 1)])
    // Reading through that dialog closes it.
    await c.deliver({ rows: [dialogRow(90, { chatId: cid(9), readMaxId: mid(1) })] })
    expect(c.fake.notifications.closedTags).toContain(tag(9, 1))
  })

  it("finds no dialog for a chat row without dialogId: no guess from a dialog row seen elsewhere (the account's settings apply)", async () => {
    const c = setup()
    c.attach()
    // The session's `dialogFor` reads `ChatRow.dialogId` only (no index of every dialog row); the core
    // sets it on every chat row and a core of another protocol never serves this UI.
    const legacy = { kind: "chat" as const, id: cid(6), title: "Legacy" }
    await c.arrive(6, message(6, 1, "x", { mentioned: true }), [ann, legacy, dialogRow(6, { notificationMode: "none" })])
    expect(c.fake.notifications.shown.map((n) => n.tag)).toEqual([tag(6, 1)])
  })

  it("keeps a notification open when the core drops its entry from the feed", async () => {
    const c = setup()
    c.attach()
    await dmWithAnn(c)
    await c.arrive(5, message(5, 51))
    const feed = c.feedSub()
    // Released after 300 s, or pushed out past the limit: the list loses it.
    await c.deliver({ lists: [{ sub: feed, keys: [] }] })
    expect(c.fake.notifications.openTags()).toEqual([tag(5, 51)])
    expect(c.attachment?.controller.openTags()).toEqual([tag(5, 51)])
  })

  it("does not notify twice for an entry replayed after a resync", async () => {
    const c = setup()
    c.attach()
    await dmWithAnn(c)
    await c.arrive(5, message(5, 51))
    const feed = c.feedSub()
    // A gap: the client asks for a resync and the core answers with a snapshot
    // whose feed still lists message 51, now with 52 after it.
    c.endpoint.patch({ base: c.endpoint.patch({ rows: [] }).revision + 5 })
    await c.flush()
    expect(c.endpoint.commands("resync")).toHaveLength(1)
    const rows = [ann, chatRow(5, { peerUserId: uid(1) }), dialogRow(5, { peerUserId: uid(1) }), message(5, 51), message(5, 52)]
    c.endpoint.deliver({
      kind: "snapshot",
      snapshot: {
        revision: 100,
        rows,
        lists: [{ sub: feed, keys: [message(5, 51), message(5, 52)].map(rowKeyOf) }],
        resources: [],
        settled: [],
      },
    })
    await c.flush()
    expect(c.fake.notifications.shown.map((n) => n.tag)).toEqual([tag(5, 51), tag(5, 52)])
  })
})

describe("permission", () => {
  it("never asks without a gesture and asks once from a trusted click", async () => {
    const c = setup()
    c.fake.notifications.setPermission("default")
    const { prompt } = c.attach()
    await dmWithAnn(c)
    await c.arrive(5, message(5, 51))
    expect(c.fake.notifications.permissionRequests).toBe(0)
    expect(c.fake.notifications.shown).toEqual([])
    expect(prompt.showPrompt.peek()).toBe(true)

    expect(await prompt.requestPermission(null)).toBe("default")
    expect(await prompt.requestPermission({ eventType: "click" } as unknown as UserGesture)).toBe("default")
    expect(userGesture({ isTrusted: false, type: "click" })).toBeNull()
    expect(c.fake.notifications.permissionRequests).toBe(0)
    expect(prompt.showPrompt.peek()).toBe(true)

    expect(await prompt.requestPermission(userGesture({ isTrusted: true, type: "click" }))).toBe("granted")
    expect(c.fake.notifications.permissionRequests).toBe(1)
    expect(prompt.showPrompt.peek()).toBe(false)
    await c.arrive(5, message(5, 52))
    expect(c.fake.notifications.shown.map((n) => n.tag)).toEqual([tag(5, 52)])
  })

  it("remembers that the affordance was dismissed", () => {
    const storage = memoryStorage()
    const c = setup()
    c.fake.notifications.setPermission("default")
    const first = c.attach({ storage })
    expect(first.prompt.showPrompt.peek()).toBe(true)
    first.prompt.dismiss()
    expect(first.prompt.showPrompt.peek()).toBe(false)
    expect(storage.data.get(PROMPT_DISMISSED_KEY)).toBe("1")
    first()

    const again = c.attach({ storage })
    expect(again.prompt.showPrompt.peek()).toBe(false)
  })

  it("survives storage that throws", () => {
    const c = setup()
    c.fake.notifications.setPermission("default")
    const broken = {
      getItem: () => {
        throw new Error("denied")
      },
      setItem: () => {
        throw new Error("denied")
      },
    }
    const { prompt } = c.attach({ storage: broken })
    expect(prompt.showPrompt.peek()).toBe(true)
    prompt.dismiss()
    expect(prompt.showPrompt.peek()).toBe(false)
  })
})
