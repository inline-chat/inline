import { describe, expect, it } from "vitest"
import { decideMessageNotification } from "@inline/platform"
import { message } from "@inline/reactive/testing"
import { addedKeys, isUnread, messageNotificationFacts, notificationDestination } from "./notifications"
import { readRetryDelayMs } from "./read-marker"
import { prominentUnreadCount, sidebarPreview, type SidebarItem } from "./sidebar-model"
import { chatRow, cid, dialogRow, draftRow, keys, mid, uid } from "./test-support"

const now = (1_700_000_050 + 30) * 1000

describe("notification facts", () => {
  const incoming = message(5, 50, "hi @me", { entities: [{ type: "mention", offset: 3, length: 3, userId: uid(3) }] })

  it("finds the rows that just arrived", () => {
    const [a, b, c] = keys(message(5, 1), message(5, 2), message(5, 3))
    expect(addedKeys([a!, b!], [a!, b!, c!])).toEqual([c])
    expect(addedKeys([a!, b!], [b!, a!])).toEqual([])
  })

  it("builds the facts for a direct message that mentions me", () => {
    const facts = messageNotificationFacts({
      message: incoming,
      me: uid(3),
      newlyInserted: true,
      chat: chatRow(5, { peerUserId: uid(2) }),
      dialog: dialogRow(5, { readMaxId: mid(49) }),
      viewingConversation: false,
      nowMs: now,
    })
    expect(facts).toMatchObject({
      outgoing: false,
      unread: true,
      directMessage: true,
      mentionsMe: true,
      chatMode: "global",
      globalMode: "all",
      dateSeconds: incoming.date,
    })
    expect(decideMessageNotification(facts)).toEqual({ notify: true, urgent: false, silent: false })
  })

  it("does not notify while viewing, for read messages, or for my own", () => {
    const base = {
      message: incoming,
      me: uid(3),
      newlyInserted: true,
      chat: chatRow(5),
      dialog: dialogRow(5),
      viewingConversation: false,
      nowMs: now,
    }
    expect(decideMessageNotification(messageNotificationFacts({ ...base, viewingConversation: true }))).toEqual({
      notify: false,
      reason: "viewing",
    })
    expect(isUnread(incoming, dialogRow(5, { readMaxId: mid(50) }))).toBe(false)
    expect(
      decideMessageNotification(messageNotificationFacts({ ...base, dialog: dialogRow(5, { readMaxId: mid(60) }) })),
    ).toEqual({ notify: false, reason: "read" })
    const mine = message(5, 51, "x", { out: true, fromId: uid(3) })
    expect(decideMessageNotification(messageNotificationFacts({ ...base, message: mine }))).toEqual({
      notify: false,
      reason: "outgoing",
    })
  })

  it("opens a notification at its message", () => {
    expect(notificationDestination(cid(5), mid(50))).toEqual({ kind: "message", chatId: cid(5), messageId: mid(50) })
    expect(notificationDestination(cid(5), undefined)).toEqual({ kind: "chat", chatId: cid(5) })
  })
})

describe("pure sidebar helpers", () => {
  it("prefers a non-empty draft over the last message", () => {
    expect(sidebarPreview(draftRow(1, "x"), message(1, 2, "y"))).toEqual({ kind: "draft", text: "x" })
    expect(sidebarPreview(undefined, message(1, 2, "", { hasUnsupportedContent: true }))).toEqual({
      kind: "message",
      text: "Message",
      outgoing: false,
    })
    expect(sidebarPreview(undefined, undefined)).toEqual({ kind: "none" })
  })

  it("counts prominent unread items", () => {
    const item = (hasUnread: boolean, prominent: boolean) => ({ hasUnread, prominent }) as SidebarItem
    expect(prominentUnreadCount([item(true, true), item(true, false), item(false, true), undefined])).toBe(1)
  })

  it("matches the Mac retry delays", () => {
    expect([1, 2, 3, 4, 5, 6].map((n) => readRetryDelayMs(n, 0.5))).toEqual([500, 1000, 2000, 4000, 8000, 8000])
    expect(readRetryDelayMs(1, 0)).toBe(400)
    expect(readRetryDelayMs(1, 1)).toBe(600)
    expect(readRetryDelayMs(5, 1)).toBe(8000)
  })
})

describe("notification facts from the row's flags and the dialog's mode", () => {
  const base = {
    me: uid(3),
    newlyInserted: true,
    chat: chatRow(6, { title: "Ops" }),
    viewingConversation: false,
    nowMs: now,
  }

  it("counts the server's mention flag (a group mention) as mentioning me", () => {
    const facts = messageNotificationFacts({
      ...base,
      message: message(6, 50, "@team look", { mentioned: true }),
      dialog: dialogRow(6, { notificationMode: "mentions" }),
    })
    expect(facts).toMatchObject({ mentionsMe: true, chatMode: "mentions" })
    expect(decideMessageNotification(facts).notify).toBe(true)
  })

  it("reads the dialog's mode, which an explicit chat mode overrides", () => {
    const quiet = { ...base, message: message(6, 50, "hello"), dialog: dialogRow(6, { notificationMode: "none" as const }) }
    expect(messageNotificationFacts(quiet).chatMode).toBe("none")
    expect(decideMessageNotification(messageNotificationFacts(quiet)).notify).toBe(false)
    expect(messageNotificationFacts({ ...quiet, chatMode: "all" }).chatMode).toBe("all")
  })

  it("never notifies a silent send", () => {
    const facts = messageNotificationFacts({ ...base, message: message(6, 50, "shh", { silent: true }), dialog: dialogRow(6) })
    expect(facts.silentSend).toBe(true)
    expect(decideMessageNotification(facts)).toMatchObject({ notify: false })
  })
})
