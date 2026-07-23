import { DbObjectKind, type Chat, type Dialog } from "@inline/client"
import { chatId, dialogId, type InlineIDInput } from "@inline/ids"
import { describe, expect, it } from "vitest"
import {
  isSidebarChatListDialog,
  sortAllChatsDialogs,
  sortSidebarDialogs,
} from "./chat-list"

const dialog = (
  id: InlineIDInput,
  changes: Partial<Dialog> = {},
): Dialog => ({
  kind: DbObjectKind.Dialog,
  id: dialogId(id),
  chatId: chatId(id),
  ...changes,
})

const chat = (id: InlineIDInput, date: number): Chat => ({
  kind: DbObjectKind.Chat,
  id: chatId(id),
  date,
})

describe("Inline chat list ordering", () => {
  it("matches the native Inbox visibility predicate", () => {
    expect(isSidebarChatListDialog(dialog(1, { open: false }))).toBe(false)
    expect(isSidebarChatListDialog(dialog(2, { open: true }))).toBe(true)
    expect(isSidebarChatListDialog(dialog(5, { pinned: true, open: false }))).toBe(true)
    expect(isSidebarChatListDialog(dialog(3, { archived: true }))).toBe(false)
    expect(isSidebarChatListDialog(dialog(4, { chatListHidden: true }))).toBe(false)
  })

  it("matches native Inbox fractional ordering", () => {
    const dialogs = [
      dialog(1, { order: "a" }),
      dialog(2, { pinned: true, pinnedOrder: "a" }),
      dialog(3, { pinned: true, pinnedOrder: "b" }),
      dialog(4, { order: "b" }),
    ]
    const chats = new Map([
      [chatId(1), chat(1, 400)],
      [chatId(2), chat(2, 200)],
      [chatId(3), chat(3, 100)],
      [chatId(4), chat(4, 300)],
    ])

    expect(sortSidebarDialogs(dialogs, chats).map((item) => item.id)).toEqual([
      dialogId(2),
      dialogId(3),
      dialogId(1),
      dialogId(4),
    ])
  })

  it("sorts All Chats by last activity instead of dialog or chat IDs", () => {
    const dialogs = [dialog(90), dialog(2), dialog(40)]
    const chats = new Map([
      [chatId(90), chat(90, 100)],
      [chatId(2), chat(2, 300)],
      [chatId(40), chat(40, 200)],
    ])

    expect(sortAllChatsDialogs(dialogs, chats).map((item) => item.id)).toEqual([
      dialogId(2),
      dialogId(40),
      dialogId(90),
    ])
  })
})
