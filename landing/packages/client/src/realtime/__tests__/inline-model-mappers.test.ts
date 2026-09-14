import { describe, expect, it } from "vitest"
import type { Dialog, Space, User } from "@inline-chat/protocol/core"
import { chatId, dialogId, spaceId, userId } from "@inline/ids"
import { Db, DbObjectKind } from "../../index"
import {
  getDialogId,
  upsertDialog,
  upsertSpace,
  upsertUser,
} from "../transactions/mappers"

describe("Inline model mappers", () => {
  it("retains the protocol avatar tiny thumbnail in the resident cache", () => {
    const db = new Db({ autoHydrate: false })
    const strippedThumb = new Uint8Array([1, 30, 40])
    const user = {
      id: 7n,
      firstName: "Dena",
      profilePhoto: {
        fileUniqueId: "avatar-7",
        cdnUrl: "https://cdn.inline.chat/avatar-7",
        strippedThumb,
      },
    } satisfies User

    upsertUser(db, user)

    expect(
      db.get(db.ref(DbObjectKind.User, userId(7)))?.profilePhoto,
    ).toEqual(
      expect.objectContaining({ strippedThumb }),
    )
  })

  it("keeps the native Inline dialog identity rules and chat-list fields", () => {
    const db = new Db({ autoHydrate: false })
    const dialog = {
      chatId: 801n,
      peer: {
        type: {
          oneofKind: "chat",
          chat: { chatId: 801n },
        },
      },
      spaceId: 23n,
      open: true,
      order: "00042",
      pinned: true,
      pinnedOrder: "00001",
      chatListHidden: false,
      unreadCount: 3,
      followMode: 2,
    } satisfies Dialog

    upsertDialog(db, dialog)

    expect(getDialogId({ peerThreadId: chatId(499) })).toBe(dialogId(499))
    expect(getDialogId({ peerThreadId: chatId(500) })).toBe(dialogId(-500))
    expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))).toMatchObject({
      chatId: chatId(801),
      peerThreadId: chatId(801),
      spaceId: spaceId(23),
      open: true,
      order: "00042",
      pinned: true,
      pinnedOrder: "00001",
      chatListHidden: false,
      unreadCount: 3,
      followMode: 2,
    })
  })

  it("stores Inline spaces as first-class cached models", () => {
    const db = new Db({ autoHydrate: false })
    const space = {
      id: 23n,
      name: "Inline",
      creator: true,
      date: 1_721_000_000n,
      isPublic: false,
    } satisfies Space

    upsertSpace(db, space)

    expect(db.get(db.ref(DbObjectKind.Space, spaceId(23)))).toEqual({
      kind: DbObjectKind.Space,
      id: spaceId(23),
      name: "Inline",
      creator: true,
      date: 1_721_000_000,
      isPublic: false,
    })
  })

  it("applies full dialog visibility while preserving omitted local inbox state", () => {
    const db = new Db({ autoHydrate: false })
    upsertDialog(db, {
      chatId: 801n,
      peer: {
        type: {
          oneofKind: "chat",
          chat: { chatId: 801n },
        },
      },
      open: true,
      order: "00042",
      chatListHidden: true,
    })

    upsertDialog(db, {
      chatId: 801n,
      peer: {
        type: {
          oneofKind: "chat",
          chat: { chatId: 801n },
        },
      },
      sidebarVisible: true,
    })

    expect(db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))).toMatchObject({
      open: true,
      order: "00042",
    })
    expect(
      db.get(db.ref(DbObjectKind.Dialog, dialogId(-801)))?.chatListHidden,
    ).toBe(false)
  })
})
