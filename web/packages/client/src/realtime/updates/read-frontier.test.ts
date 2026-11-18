import { Update } from "@inline-chat/protocol/core"
import { chatId, messageId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import { getDialogId, upsertDialog } from "../transactions/mappers"
import { applyUpdates, applyUpdateSidecars } from "./apply-updates"

const peer = { type: { oneofKind: "chat" as const, chat: { chatId: 10n } } }
const dialogRef = (db: Db) =>
  db.ref(DbObjectKind.Dialog, getDialogId({ peerThreadId: chatId(10) }))

const setup = (readMaxId: number, unreadCount: number) => {
  const db = new Db({ autoHydrate: false })
  upsertDialog(db, {
    peer,
    chatId: 10n,
    readMaxId: BigInt(readMaxId),
    unreadCount,
    archived: true,
  })
  return db
}

const read = (readMaxId: number, unreadCount: number) =>
  Update.create({
    update: {
      oneofKind: "updateReadMaxId",
      updateReadMaxId: { peerId: peer, readMaxId: BigInt(readMaxId), unreadCount },
    },
  })

describe("the read frontier only moves forward", () => {
  it("ignores a replayed read at or behind the stored frontier", () => {
    const db = setup(2, 1)
    applyUpdates(db, [read(2, 0)], "syncCatchup")
    applyUpdates(db, [read(1, 5)], "realtime")
    expect(db.get(dialogRef(db))).toMatchObject({
      readMaxId: messageId(2),
      unreadCount: 1,
    })
    applyUpdates(db, [read(3, 0)], "realtime")
    expect(db.get(dialogRef(db))).toMatchObject({
      readMaxId: messageId(3),
      unreadCount: 0,
    })
  })

  it("keeps the stored frontier and its count when a snapshot is older", () => {
    const db = setup(5, 2)
    upsertDialog(db, { peer, chatId: 10n, readMaxId: 3n, unreadCount: 9 })
    expect(db.get(dialogRef(db))).toMatchObject({
      readMaxId: messageId(5),
      unreadCount: 2,
    })
  })

  it("takes only read state from a sidecar for a stored dialog, never user-owned fields", () => {
    const db = setup(2, 1)
    const report = applyUpdateSidecars(db, {
      users: [],
      chats: [{ id: 10n, title: "Chat", seq: 7 }],
      dialogs: [
        { peer, chatId: 10n, readMaxId: 2n, unreadCount: 4, archived: false },
      ],
      spaces: [],
      userGroups: [],
    })
    expect(db.get(dialogRef(db))).toMatchObject({
      readMaxId: messageId(2),
      unreadCount: 4,
      archived: true,
    })
    expect(report.countedChats).toEqual([{ chatId: chatId(10), seq: 7 }])

    // Behind the stored frontier: nothing is taken, nothing is counted.
    const stale = applyUpdateSidecars(db, {
      users: [],
      chats: [{ id: 10n, title: "Chat", seq: 8 }],
      dialogs: [{ peer, chatId: 10n, readMaxId: 1n, unreadCount: 9 }],
      spaces: [],
      userGroups: [],
    })
    expect(db.get(dialogRef(db))).toMatchObject({ unreadCount: 4 })
    expect(stale.countedChats).toEqual([])
  })
})
