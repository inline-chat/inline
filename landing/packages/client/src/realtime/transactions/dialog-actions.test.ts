import {
  DialogFollowMode,
  Method,
  Update,
  type InputPeer,
  type Peer,
} from "@inline-chat/protocol/core"
import { chatId, dialogId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import { decodePendingTransaction } from "./transaction-registry"
import { updateDialogFollowMode } from "./update-dialog-follow-mode"
import { updateDialogOpen } from "./update-dialog-open"
import { updateDialogOrder } from "./update-dialog-order"

const peerId: InputPeer = {
  type: {
    oneofKind: "chat",
    chat: { chatId: 801n },
  },
}

const peer: Peer = {
  type: {
    oneofKind: "chat",
    chat: { chatId: 801n },
  },
}

const makeDb = () => {
  const db = new Db({ autoHydrate: false, persistence: false })
  db.insert({
    kind: DbObjectKind.Chat,
    id: chatId(801),
    parentChatId: chatId(400),
  })
  db.insert({
    kind: DbObjectKind.Dialog,
    id: dialogId(-801),
    chatId: chatId(801),
    peerThreadId: chatId(801),
    open: true,
    order: "m",
    pinned: false,
  })
  return db
}

describe("Inline dialog action transactions", () => {
  it("pins through the exact update-dialog-order state setter", () => {
    const db = makeDb()
    const transaction = updateDialogOrder({ peerId, pinned: true })

    expect(transaction.method).toBe(Method.UPDATE_DIALOG_ORDER)
    expect(transaction.persistence).toEqual({
      type: "update_dialog_order",
      replayPolicy: "idempotent",
    })
    expect(transaction.input(transaction.context)).toMatchObject({
      oneofKind: "updateDialogOrder",
      updateDialogOrder: { peerId, pinned: true },
    })

    transaction.prepare(db)
    transaction.optimistic(db)
    expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))).toMatchObject({
      pinned: true,
      open: true,
      archived: false,
      order: "m",
    })
    expect(
      db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))?.pinnedOrder,
    ).toMatch(/^~local:pinned:/)
  })

  it("applies the authoritative pinned dialog and remains replayable", () => {
    const db = makeDb()
    const transaction = updateDialogOrder({ peerId, pinned: true })
    transaction.apply(
      {
        oneofKind: "updateDialogOrder",
        updateDialogOrder: {
          chat: { id: 801n, title: "Reply thread" },
          dialog: {
            peer,
            chatId: 801n,
            open: true,
            order: "m",
            pinned: true,
            pinnedOrder: "z",
          },
        },
      },
      db,
    )

    expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))).toMatchObject({
      pinned: true,
      pinnedOrder: "z",
    })
    expect(
      decodePendingTransaction({
        kind: DbObjectKind.PendingTransaction,
        id: "pin",
        type: "update_dialog_order",
        replayPolicy: "idempotent",
        context: transaction.context,
        createdAt: 1,
        status: "pending",
      }),
    ).toBeDefined()
  })

  it("follows a reply thread optimistically and applies server updates", () => {
    const db = makeDb()
    const transaction = updateDialogFollowMode({
      peerId,
      selection: "following",
    })

    expect(transaction.method).toBe(Method.UPDATE_DIALOG_FOLLOW_MODE)
    expect(transaction.persistence).toEqual({
      type: "update_dialog_follow_mode",
      replayPolicy: "idempotent",
    })
    expect(transaction.input(transaction.context)).toEqual({
      oneofKind: "updateDialogFollowMode",
      updateDialogFollowMode: {
        peerId,
        followMode: DialogFollowMode.FOLLOWING,
      },
    })

    transaction.prepare(db)
    transaction.optimistic(db)
    expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))).toMatchObject({
      followMode: DialogFollowMode.FOLLOWING,
      open: true,
    })

    transaction.apply(
      {
        oneofKind: "updateDialogFollowMode",
        updateDialogFollowMode: {
          updates: [
            Update.create({
              update: {
                oneofKind: "dialogFollowMode",
                dialogFollowMode: {
                  peerId: peer,
                  followMode: DialogFollowMode.UNFOLLOWED,
                },
              },
            }),
          ],
        },
      },
      db,
    )
    expect(
      db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))?.followMode,
    ).toBe(DialogFollowMode.UNFOLLOWED)
  })

  it("encodes relevance as absence and restores a follow intent", () => {
    const transaction = updateDialogFollowMode({
      peerId,
      selection: "relevance",
    })
    expect(transaction.input(transaction.context)).toEqual({
      oneofKind: "updateDialogFollowMode",
      updateDialogFollowMode: { peerId, followMode: undefined },
    })
    expect(
      decodePendingTransaction({
        kind: DbObjectKind.PendingTransaction,
        id: "follow",
        type: "update_dialog_follow_mode",
        replayPolicy: "idempotent",
        context: transaction.context,
        createdAt: 1,
        status: "pending",
      }),
    ).toBeDefined()
  })

  it("does not let a late Close result overwrite a later Pin intent", () => {
    const db = makeDb()
    const close = updateDialogOpen({ peerId, open: false })
    close.prepare(db)
    close.optimistic(db)

    const pin = updateDialogOrder({ peerId, pinned: true })
    pin.prepare(db)
    pin.optimistic(db)

    close.apply(
      {
        oneofKind: "updateDialogOpen",
        updateDialogOpen: {
          chat: { id: 801n, title: "Reply thread" },
          dialog: {
            peer,
            chatId: 801n,
            open: false,
            pinned: false,
          },
        },
      },
      db,
    )

    expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))).toMatchObject({
      open: true,
      pinned: true,
    })
  })

  it("rolls back a rejected Follow field without undoing a later Pin", () => {
    const db = makeDb()
    const follow = updateDialogFollowMode({
      peerId,
      selection: "following",
    })
    follow.prepare(db)
    follow.optimistic(db)

    const pin = updateDialogOrder({ peerId, pinned: true })
    pin.prepare(db)
    pin.optimistic(db)

    follow.failed(new Error("rejected"), db)

    expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))).toMatchObject({
      followMode: undefined,
      open: true,
      pinned: true,
    })
  })
})
