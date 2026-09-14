import { Method, type InputPeer } from "@inline-chat/protocol/core"
import { chatId, dialogId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import {
  showInChatList,
  updateDialogOpen,
} from "../transactions"

const peerId: InputPeer = {
  type: {
    oneofKind: "chat",
    chat: { chatId: 801n },
  },
}

const protocolPeer = {
  type: {
    oneofKind: "chat" as const,
    chat: { chatId: 801n },
  },
}

describe("macOS Inbox transactions", () => {
  it("shows a hidden thread and opens it optimistically before the RPC returns", () => {
    const db = new Db({ autoHydrate: false })
    db.insert({
      kind: DbObjectKind.Dialog,
      id: dialogId(-801),
      chatId: chatId(801),
      peerThreadId: chatId(801),
      open: false,
      chatListHidden: true,
    })

    const show = showInChatList({ peerId })
    expect(show.method).toBe(Method.SHOW_IN_CHAT_LIST)
    expect(show.input(show.context)).toMatchObject({
      oneofKind: "showInChatList",
      showInChatList: { peerId },
    })
    show.optimistic(db)

    const open = updateDialogOpen({ peerId, open: true })
    expect(open.method).toBe(Method.UPDATE_DIALOG_OPEN)
    expect(open.input(open.context)).toMatchObject({
      oneofKind: "updateDialogOpen",
      updateDialogOpen: {
        peerId,
        open: true,
      },
    })
    open.optimistic(db)

    expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))).toMatchObject({
      open: true,
      archived: false,
    })
    expect(
      db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))?.chatListHidden,
    ).toBeUndefined()
  })

  it("commits the server Inbox order and visible chat-list state", async () => {
    const db = new Db({ autoHydrate: false })
    db.insert({
      kind: DbObjectKind.Dialog,
      id: dialogId(-801),
      chatId: chatId(801),
      peerThreadId: chatId(801),
      open: false,
      chatListHidden: true,
    })

    const show = showInChatList({ peerId })
    show.optimistic(db)
    await show.apply(
      {
        oneofKind: "showInChatList",
        showInChatList: {
          chat: {
            id: 801n,
            title: "Thread",
            peerId: protocolPeer,
          },
          dialog: {
            chatId: 801n,
            peer: protocolPeer,
            sidebarVisible: true,
          },
        },
      },
      db,
    )

    const open = updateDialogOpen({ peerId, open: true })
    open.optimistic(db)
    await open.apply(
      {
        oneofKind: "updateDialogOpen",
        updateDialogOpen: {
          chat: {
            id: 801n,
            title: "Thread",
            peerId: protocolPeer,
          },
          dialog: {
            chatId: 801n,
            peer: protocolPeer,
            open: true,
            order: "a0",
            sidebarVisible: true,
          },
        },
      },
      db,
    )

    expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))).toMatchObject({
      open: true,
      order: "a0",
      chatListHidden: false,
    })
  })

  it("isolates open intents by account database", () => {
    const first = new Db({ autoHydrate: false })
    const second = new Db({ autoHydrate: false })
    for (const db of [first, second]) {
      db.insert({
        kind: DbObjectKind.Dialog,
        id: dialogId(-801),
        chatId: chatId(801),
        peerThreadId: chatId(801),
        open: false,
      })
    }

    const firstOpen = updateDialogOpen({ peerId, open: true })
    firstOpen.optimistic(first)
    updateDialogOpen({ peerId, open: false }).optimistic(second)
    firstOpen.apply(
      {
        oneofKind: "updateDialogOpen",
        updateDialogOpen: {
          chat: {
            id: 801n,
            title: "First account thread",
            peerId: protocolPeer,
          },
          dialog: {
            chatId: 801n,
            peer: protocolPeer,
            open: true,
            order: "server-a",
            sidebarVisible: true,
          },
        },
      },
      first,
    )

    expect(
      first.get(first.ref(DbObjectKind.Dialog, dialogId(-801))),
    ).toMatchObject({ open: true, order: "server-a" })
    expect(
      second.get(second.ref(DbObjectKind.Dialog, dialogId(-801)))?.open,
    ).toBe(false)
  })

  it("rolls back a failed close only while it remains the newest intent", async () => {
    const db = new Db({ autoHydrate: false })
    db.insert({
      kind: DbObjectKind.Dialog,
      id: dialogId(-801),
      chatId: chatId(801),
      peerThreadId: chatId(801),
      open: true,
      order: "a0",
      archived: false,
    })
    const close = updateDialogOpen({ peerId, open: false })
    close.prepare(db)
    close.optimistic(db)
    expect(
      db.get(db.ref(DbObjectKind.Dialog, dialogId(-801))),
    ).toMatchObject({ open: false, order: undefined })

    await close.failed(new Error("server refused close"), db)
    expect(
      db.get(db.ref(DbObjectKind.Dialog, dialogId(-801))),
    ).toMatchObject({ open: true, order: "a0", archived: false })

    const open = updateDialogOpen({ peerId, open: true })
    open.optimistic(db)
    const newerClose = updateDialogOpen({ peerId, open: false })
    newerClose.optimistic(db)
    await open.failed(new Error("stale open failure"), db)
    expect(
      db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))?.open,
    ).toBe(false)
  })

  it("does not let a stale open response undo a newer close", () => {
    const db = new Db({ autoHydrate: false })
    db.insert({
      kind: DbObjectKind.Dialog,
      id: dialogId(-801),
      chatId: chatId(801),
      peerThreadId: chatId(801),
      open: false,
    })
    const open = updateDialogOpen({ peerId, open: true })
    open.optimistic(db)
    updateDialogOpen({ peerId, open: false }).optimistic(db)

    open.apply(
      {
        oneofKind: "updateDialogOpen",
        updateDialogOpen: {
          chat: {
            id: 801n,
            title: "Thread",
            peerId: protocolPeer,
          },
          dialog: {
            chatId: 801n,
            peer: protocolPeer,
            open: true,
            order: "stale-open",
            sidebarVisible: true,
          },
        },
      },
      db,
    )

    expect(
      db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))?.open,
    ).toBe(false)
  })
})
