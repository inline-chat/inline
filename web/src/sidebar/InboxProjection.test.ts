import { describe, expect, it } from "vitest"
import { DbObjectKind, type Chat, type Dialog } from "@inline/client"
import { chatId, dialogId } from "@inline/ids"
import { projectInbox } from "./InboxProjection"

const dialog = (id: number, pinned = false): Dialog => ({
  kind: DbObjectKind.Dialog,
  id: dialogId(id),
  chatId: chatId(id),
  peerThreadId: chatId(id),
  pinned,
})

const chat = (id: number, parent?: number): Chat => ({
  kind: DbObjectKind.Chat,
  id: chatId(id),
  parentChatId: parent == null ? undefined : chatId(parent),
})

describe("projectInbox", () => {
  it("keeps attached replies in stable pre-order", () => {
    const dialogs = [dialog(1), dialog(3), dialog(2), dialog(4)]
    const chats = [chat(1), chat(3), chat(2, 1), chat(4, 2)]
    const rows = projectInbox({
      dialogs,
      chatsById: new Map(chats.map((value) => [value.id, value])),
    })

    expect(rows.map((row) => [row.dialog.id, row.depth])).toEqual([
      [dialogId(1), 0],
      [dialogId(2), 1],
      [dialogId(4), 2],
      [dialogId(3), 0],
    ])
    expect(rows[0]?.closeGroupDialogs.map(({ id }) => id)).toEqual([
      dialogId(1),
      dialogId(2),
      dialogId(4),
    ])
  })

  it("detaches a pinned reply from an unpinned parent", () => {
    const parent = dialog(1)
    const child = dialog(2, true)
    const rows = projectInbox({
      dialogs: [child, parent],
      chatsById: new Map([
        [chatId(1), chat(1)],
        [chatId(2), chat(2, 1)],
      ]),
    })

    expect(rows.map((row) => [row.dialog.id, row.depth, row.detached])).toEqual([
      [dialogId(2), 0, true],
      [dialogId(1), 0, false],
    ])
    expect(rows[1]?.closeGroupDialogs.map(({ id }) => id)).toEqual([
      dialogId(1),
    ])
  })

  it("collapses descendants but reveals the selected reply", () => {
    const dialogs = [dialog(1), dialog(2), dialog(3)]
    const chats = new Map([
      [chatId(1), chat(1)],
      [chatId(2), chat(2, 1)],
      [chatId(3), chat(3, 2)],
    ])
    expect(projectInbox({
      dialogs,
      chatsById: chats,
      collapsedDialogIds: new Set([dialogId(1)]),
    }).map((row) => row.dialog.id)).toEqual([dialogId(1)])

    expect(projectInbox({
      dialogs,
      chatsById: chats,
      collapsedDialogIds: new Set([dialogId(1), dialogId(2)]),
      selectedDialogId: dialogId(3),
    }).map((row) => row.dialog.id)).toEqual([
      dialogId(1),
      dialogId(2),
      dialogId(3),
    ])
  })

  it("keeps invalid cycles visible once", () => {
    const rows = projectInbox({
      dialogs: [dialog(1), dialog(2)],
      chatsById: new Map([
        [chatId(1), chat(1, 2)],
        [chatId(2), chat(2, 1)],
      ]),
    })
    expect(rows.map((row) => row.dialog.id).sort()).toEqual([
      dialogId(1),
      dialogId(2),
    ])
  })
})
