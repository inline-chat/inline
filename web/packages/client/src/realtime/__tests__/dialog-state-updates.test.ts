import {
  DialogNotificationSettings_Mode,
  NotificationSettings_Mode,
  Update,
} from "@inline-chat/protocol/core"
import { inlineId, messageId, spaceId, userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import { DbQueryPlanType } from "../../database/types"
import { getChats } from "../transactions/get-chats"
import { getSpace } from "../transactions/get-space"
import { getSpaces } from "../transactions/get-spaces"
import { getUserSettings } from "../transactions/get-user-settings"
import { getDialogId, upsertDialog } from "../transactions/mappers"
import { updateUserSettings } from "../transactions/update-user-settings"
import { TransactionErrors } from "../transactions/transaction-errors"
import { applyUpdates } from "../updates/apply-updates"
import { readUserSettings } from "../updates/settings"
import { chatPeer, SPACE, seedAccount, THREAD, update } from "./update-coverage-fixtures"

const threadDialog = (db: Db) =>
  db.get(db.ref(DbObjectKind.Dialog, getDialogId({ peerThreadId: THREAD })))

const seeded = () => {
  const db = new Db({ autoHydrate: false })
  seedAccount(db)
  return db
}

describe("per-dialog state", () => {
  it("sets and resets the notification mode; a dialog not stored yet is left to its snapshot", () => {
    const db = seeded()
    const setting = (seq: number, mode?: DialogNotificationSettings_Mode, chat = 10n) =>
      update(seq, {
        oneofKind: "dialogNotificationSettings",
        dialogNotificationSettings: {
          peerId: chatPeer(chat),
          ...(mode != null ? { notificationSettings: { mode } } : {}),
        },
      })
    applyUpdates(db, [setting(1, DialogNotificationSettings_Mode.NONE)])
    expect(threadDialog(db)?.notificationMode).toBe("none")
    applyUpdates(db, [setting(2, DialogNotificationSettings_Mode.UNSPECIFIED)])
    expect(threadDialog(db)?.notificationMode).toBeUndefined()
    applyUpdates(db, [setting(3, DialogNotificationSettings_Mode.ALL), setting(4)])
    expect(threadDialog(db)?.notificationMode).toBeUndefined()

    expect(applyUpdates(db, [setting(5, DialogNotificationSettings_Mode.ALL, 999n)])).toMatchObject({
      applied: 1,
      deferred: 0,
    })
    expect(db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.DeferredUpdate)).toEqual([])
  })

  it("keeps unread activity as sets: duplicates change nothing and clearing wins", () => {
    const db = seeded()
    const activity = (seq: number, value: object) =>
      update(seq, {
        oneofKind: "unreadActivity",
        unreadActivity: {
          peerId: chatPeer(10n),
          unreadMentionsCount: 0,
          unreadReactionsCount: 0,
          unreadMentionIds: [],
          unreadReactionIds: [],
          clearedMessageIds: [],
          ...value,
        },
      })
    const first = activity(1, {
      unreadMentionsCount: 2,
      unreadReactionsCount: 1,
      unreadMentionIds: [6n, 5n],
      unreadReactionIds: [7n],
    })
    applyUpdates(db, [first, first])
    expect(threadDialog(db)).toMatchObject({
      unreadMentionsCount: 2,
      unreadReactionsCount: 1,
      unreadMentionIds: [messageId(5), messageId(6)],
      unreadReactionIds: [messageId(7)],
    })
    applyUpdates(db, [
      activity(2, {
        unreadMentionsCount: 2,
        unreadReactionsCount: 0,
        unreadMentionIds: [8n, 5n],
        clearedMessageIds: [5n, 7n],
      }),
    ])
    expect(threadDialog(db)).toMatchObject({
      unreadMentionsCount: 2,
      unreadReactionsCount: 0,
      unreadMentionIds: [messageId(6), messageId(8)],
    })
    expect(threadDialog(db)?.unreadReactionIds).toBeUndefined()
  })

  it("takes folder, mode and translation from a dialog snapshot, and keeps activity counts it leaves out", () => {
    const db = seeded()
    applyUpdates(db, [
      update(1, {
        oneofKind: "unreadActivity",
        unreadActivity: {
          peerId: chatPeer(10n),
          unreadMentionsCount: 3,
          unreadReactionsCount: 1,
          unreadMentionIds: [4n],
          unreadReactionIds: [],
          clearedMessageIds: [],
        },
      }),
    ])
    upsertDialog(db, {
      peer: chatPeer(10n),
      chatId: 10n,
      folderId: 40n,
      translationEnabled: true,
      notificationSettings: { mode: DialogNotificationSettings_Mode.MENTIONS },
    })
    expect(threadDialog(db)).toMatchObject({
      folderId: inlineId(40),
      translationEnabled: true,
      notificationMode: "mentions",
      unreadMentionsCount: 3,
      unreadMentionIds: [messageId(4)],
    })
    upsertDialog(db, { peer: chatPeer(10n), chatId: 10n, unreadMentionsCount: 0 })
    expect(threadDialog(db)).toMatchObject({ unreadMentionsCount: 0, unreadReactionsCount: 1 })
    expect(threadDialog(db)?.folderId).toBeUndefined()
    expect(threadDialog(db)?.notificationMode).toBeUndefined()
    expect(threadDialog(db)?.unreadMentionIds).toBeUndefined()
  })

  it("getChats replaces the folder list", () => {
    const db = seeded()
    db.replace({ kind: DbObjectKind.DialogFolder, id: inlineId(1), order: "a" })
    getChats().apply(
      {
        oneofKind: "getChats",
        getChats: {
          dialogs: [],
          chats: [],
          spaces: [],
          users: [],
          messages: [],
          folders: [{ id: 2n, order: "b", title: "Later", pinnedOrder: "p" }],
        },
      },
      db,
    )
    expect(db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.DialogFolder)).toEqual([
      { kind: DbObjectKind.DialogFolder, id: inlineId(2), order: "b", title: "Later", pinnedOrder: "p" },
    ])
  })
})

describe("user settings", () => {
  it("merges server settings: a group sent replaces the stored one, a group left out stays", () => {
    const db = seeded()
    applyUpdates(db, [
      update(1, {
        oneofKind: "updateUserSettings",
        updateUserSettings: {
          settings: {
            notificationSettings: { mode: NotificationSettings_Mode.IMPORTANT_ONLY, silent: true },
            messageGestureSettings: { doubleTapAction: "react" },
          },
        },
      }),
      update(2, {
        oneofKind: "updateUserSettings",
        updateUserSettings: {
          settings: { notificationSettings: { mode: NotificationSettings_Mode.NONE } },
        },
      }),
    ])
    expect(readUserSettings(db)).toEqual({
      kind: DbObjectKind.UserSettings,
      id: 0,
      notifications: { mode: "none" },
      messageGestures: { doubleTapAction: "react" },
    })

    getUserSettings().apply(
      {
        oneofKind: "getUserSettings",
        getUserSettings: {
          userSettings: { privacySettings: { appearInGlobalSearch: false } },
        },
      },
      db,
    )
    expect(readUserSettings(db)).toMatchObject({
      notifications: { mode: "none" },
      privacy: { appearInGlobalSearch: false },
    })
  })

  it("UPDATE_USER_SETTINGS overlays the patch, takes the server's merged settings, and rolls back on failure", () => {
    const db = seeded()
    applyUpdates(db, [
      update(1, {
        oneofKind: "updateUserSettings",
        updateUserSettings: { settings: { notificationSettings: { mode: NotificationSettings_Mode.ALL } } },
      }),
    ])
    const before = readUserSettings(db)

    const failing = updateUserSettings({ notifications: { silent: true } })
    expect(failing.input(failing.context)).toEqual({
      oneofKind: "updateUserSettings",
      updateUserSettings: { userSettings: { notificationSettings: { silent: true } } },
    })
    failing.optimistic(db)
    expect(readUserSettings(db)?.notifications).toEqual({ mode: "all", silent: true })
    failing.failed(TransactionErrors.timeout(), db)
    expect(readUserSettings(db)).toEqual(before)

    const accepted = updateUserSettings({ notifications: { silent: true } })
    accepted.optimistic(db)
    accepted.apply(
      {
        oneofKind: "updateUserSettings",
        updateUserSettings: {
          updates: [
            Update.create({
              seq: 2,
              date: 2n,
              update: {
                oneofKind: "updateUserSettings",
                updateUserSettings: {
                  settings: {
                    notificationSettings: { mode: NotificationSettings_Mode.ALL, silent: true },
                  },
                },
              },
            }),
          ],
        },
      },
      db,
    )
    expect(readUserSettings(db)?.notifications).toEqual({ mode: "all", silent: true })
  })
})

describe("space wrappers", () => {
  it("GET_SPACES and GET_SPACE store the spaces, the account's membership and the settings", () => {
    const db = seeded()
    getSpaces().apply(
      {
        oneofKind: "getSpaces",
        getSpaces: {
          spaces: [{ id: 6n, name: "Six", creator: true, date: 600n, handle: "six", seq: 3, isPro: true }],
        },
      },
      db,
    )
    expect(db.get(db.ref(DbObjectKind.Space, spaceId(6)))).toMatchObject({
      name: "Six",
      handle: "six",
      seq: 3,
      isPro: true,
    })
    getSpace({ spaceId: SPACE }).apply(
      {
        oneofKind: "getSpace",
        getSpace: {
          space: { id: 5n, name: "Five", creator: false, date: 100n, seq: 9 },
          membership: { id: 70n, spaceId: 5n, userId: 1n, date: 100n, canAccessPublicChats: true },
          settings: { spaceId: 5n, gridEnabled: true },
        },
      },
      db,
    )
    expect(db.get(db.ref(DbObjectKind.Space, SPACE))).toMatchObject({
      name: "Five",
      seq: 9,
      gridEnabled: true,
    })
    expect(
      db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.SpaceMember).map((row) => row.userId),
    ).toEqual([userId(1)])
  })
})
