import {
  DialogNotificationSettings_Mode,
  Member_Role,
  NotificationSettings_Mode,
  type Update,
} from "@inline-chat/protocol/core"
import { describe, expect, it } from "vitest"
import { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import { createSqliteMemoryPersistenceStore } from "../../database/sqlite/openers"
import { DbQueryPlanType } from "../../database/types"
import { syncBucketId, type SyncBucketKey } from "../sync/sync-types"
import { applyUpdates, deferredUpdateRecord } from "../updates/apply-updates"
import { bindAccountUser } from "../updates/account-context"
import { replayProjectedDeferredUpdates } from "../updates/deferred-replay"
import {
  chatPeer,
  createSyncEngine,
  JournalClient,
  observe,
  observeStored,
  SELF,
  seedAccount,
  update,
} from "./update-coverage-fixtures"

/*
 * Every update kind projected since schema version 4, through the real sync
 * engine and the real store on SQLite: applied in order, duplicates ignored,
 * a record pushed ahead of the cursor waits for the gap to be fetched, the
 * models round-trip through SQLite, and raw rows stored by an older build
 * replay into the same state.
 */

type CoverageCase = {
  name: string
  bucket: SyncBucketKey
  updates: Update[]
}

const user = { kind: "user" } as const
const space = { kind: "space", spaceId: "5" } as SyncBucketKey

const member = (id: bigint, userId: bigint, role = Member_Role.MEMBER) => ({
  id,
  spaceId: 5n,
  userId,
  role,
  date: 1_000n,
  canAccessPublicChats: true,
})

const threadDialog = (extra: object = {}) => ({
  peer: chatPeer(10n),
  chatId: 10n,
  spaceId: 5n,
  notificationSettings: { mode: DialogNotificationSettings_Mode.MENTIONS },
  translationEnabled: true,
  ...extra,
})

const cases: CoverageCase[] = [
  {
    name: "space members",
    bucket: space,
    updates: [
      update(1, {
        oneofKind: "spaceMemberAdd",
        spaceMemberAdd: { member: member(100n, 3n), user: { id: 3n, firstName: "Three" } },
      }),
      update(2, {
        oneofKind: "spaceMemberUpdate",
        spaceMemberUpdate: { member: member(100n, 3n, Member_Role.ADMIN) },
      }),
      update(3, {
        oneofKind: "spaceMemberAdd",
        spaceMemberAdd: { member: member(101n, 4n) },
      }),
      update(4, {
        oneofKind: "spaceMemberDelete",
        spaceMemberDelete: { spaceId: 5n, userId: 3n, memberId: 100n },
      }),
      update(5, {
        oneofKind: "spaceMemberAdd",
        spaceMemberAdd: { member: member(102n, 3n) },
      }),
    ],
  },
  {
    name: "space settings and profile",
    bucket: space,
    updates: [
      update(1, {
        oneofKind: "spaceSettings",
        spaceSettings: { spaceId: 5n, settings: { spaceId: 5n, gridEnabled: true } },
      }),
      update(2, {
        oneofKind: "spaceProfile",
        spaceProfile: { spaceId: 5n, photoFileUniqueId: "a", isPro: true },
      }),
      update(3, {
        oneofKind: "spaceSettings",
        spaceSettings: { spaceId: 5n, settings: { spaceId: 5n, gridEnabled: false } },
      }),
      update(4, {
        oneofKind: "spaceProfile",
        spaceProfile: { spaceId: 5n, photoFileUniqueId: "b", isPro: false },
      }),
    ],
  },
  {
    name: "dialog state, folders, unread activity and user settings",
    bucket: user,
    updates: [
      update(1, {
        oneofKind: "joinSpace",
        joinSpace: {
          space: { id: 6n, name: "Joined", creator: false, date: 500n },
          member: { ...member(200n, 1n), spaceId: 6n },
        },
      }),
      update(2, {
        oneofKind: "dialogNotificationSettings",
        dialogNotificationSettings: {
          peerId: chatPeer(10n),
          notificationSettings: { mode: DialogNotificationSettings_Mode.MENTIONS },
        },
      }),
      update(3, {
        oneofKind: "dialogTranslation",
        dialogTranslation: { peerId: chatPeer(10n), enabled: true },
      }),
      update(4, {
        oneofKind: "dialogFolder",
        dialogFolder: {
          folderChange: {
            oneofKind: "folder",
            folder: { id: 40n, title: "Work", order: "a", emoji: "💼" },
          },
          dialogs: [threadDialog({ folderId: 40n })],
        },
      }),
      update(5, {
        oneofKind: "unreadActivity",
        unreadActivity: {
          peerId: chatPeer(10n),
          unreadMentionsCount: 2,
          unreadReactionsCount: 1,
          unreadMentionIds: [5n, 6n],
          unreadReactionIds: [7n],
          clearedMessageIds: [],
        },
      }),
      update(6, {
        oneofKind: "updateUserSettings",
        updateUserSettings: {
          settings: {
            notificationSettings: { mode: NotificationSettings_Mode.MENTIONS, silent: true },
            composeSettings: { replacePastedLinksWithTitles: true },
          },
        },
      }),
      update(7, {
        oneofKind: "unreadActivity",
        unreadActivity: {
          peerId: chatPeer(10n),
          unreadMentionsCount: 1,
          unreadReactionsCount: 0,
          unreadMentionIds: [],
          unreadReactionIds: [],
          clearedMessageIds: [5n, 7n],
        },
      }),
      update(8, {
        oneofKind: "dialogNotificationSettings",
        dialogNotificationSettings: {
          peerId: { type: { oneofKind: "user", user: { userId: 2n } } },
          notificationSettings: { mode: DialogNotificationSettings_Mode.NONE },
        },
      }),
      update(9, {
        oneofKind: "dialogFolder",
        dialogFolder: {
          folderChange: { oneofKind: "deletedFolderId", deletedFolderId: 40n },
          dialogs: [threadDialog()],
        },
      }),
      update(10, {
        oneofKind: "updateUserSettings",
        updateUserSettings: {
          settings: {
            notificationSettings: { mode: NotificationSettings_Mode.ALL },
          },
        },
      }),
    ],
  },
  {
    name: "chat participants, group grants and access changes",
    bucket: user,
    updates: [
      update(1, {
        oneofKind: "participantAdd",
        participantAdd: { chatId: 10n, participant: { userId: 3n, date: 1_001n } },
      }),
      update(2, {
        oneofKind: "participantGroupAdd",
        participantGroupAdd: { chatId: 10n, groupParticipant: { groupId: 30n, date: 1_002n } },
      }),
      update(3, {
        oneofKind: "userAddedToChat",
        userAddedToChat: { chatId: 10n, participant: { userId: 1n, date: 1_003n } },
      }),
      update(4, {
        oneofKind: "participantDelete",
        participantDelete: { chatId: 10n, userId: 3n },
      }),
      update(5, {
        oneofKind: "userRemovedFromChat",
        userRemovedFromChat: { chatId: 12n },
      }),
      update(6, {
        oneofKind: "participantAdd",
        participantAdd: { chatId: 10n, participant: { userId: 4n, date: 1_006n } },
      }),
    ],
  },
]

const reference = (updates: Update[]) => {
  const db = new Db({ autoHydrate: false })
  seedAccount(db)
  applyUpdates(db, updates, "syncCatchup")
  return observe(db)
}

describe("update coverage: projected kinds through sync", () => {
  it.each(cases)(
    "$name: applies in order, ignores duplicates, waits out a gap and round-trips through SQLite",
    async ({ bucket, updates }) => {
      const store = createSqliteMemoryPersistenceStore()
      const db = new Db({ autoHydrate: false, persistenceStore: store })
      seedAccount(db)
      await db.flushPersistence()
      const client = new JournalClient()
      client.journal(bucket, updates)
      const engine = createSyncEngine(db, client)
      await engine.connectionOpened()
      await engine.idle()

      const n = updates.length
      // The second record arrives live before the first was served: a gap.
      client.publish(bucket, 2)
      await engine.processPush([updates[1]!])
      await engine.idle()
      // Both again: duplicates of what the cursor already covers.
      await engine.processPush([updates[0]!, updates[1]!])
      await engine.idle()
      // The last record arrives ahead of everything between.
      client.publish(bucket, n)
      await engine.processPush([updates[n - 1]!])
      await engine.idle()
      // The whole journal again, newest first.
      await engine.processPush(updates.slice().reverse())
      await engine.idle()
      await engine.stop()
      await db.flushPersistence()

      const expected = reference(updates)
      expect(observe(db)).toEqual(expected)
      expect(await observeStored(store)).toEqual(expected)
      expect(
        db.get(db.ref(DbObjectKind.SyncBucketState, syncBucketId(bucket)))?.seq,
      ).toBe(n)
      // Nothing of these kinds is left raw.
      expect(
        db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.DeferredUpdate),
      ).toEqual([])
    },
  )

  it.each(cases)(
    "$name: replays raw rows an older build stored, into the same state",
    async ({ updates }) => {
      const store = createSqliteMemoryPersistenceStore()
      const older = new Db({ autoHydrate: false, persistenceStore: store })
      seedAccount(older)
      // What the build before schema version 4 wrote for these kinds.
      older.batch(() => {
        for (const raw of updates) older.replace(deferredUpdateRecord(raw))
      })
      await older.flushPersistence()

      const db = new Db({ persistenceStore: store })
      await db.ready
      bindAccountUser(db, () => SELF)
      expect(
        db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.DeferredUpdate),
      ).toEqual([])

      const report = await replayProjectedDeferredUpdates(db)
      expect(report).toEqual({ applied: updates.length, retained: 0 })
      await db.flushPersistence()
      expect(observe(db)).toEqual(reference(updates))
      expect(
        await store.collection(DbObjectKind.DeferredUpdate).getAll(),
      ).toEqual([])

      // Replaying again finds nothing: the rows were consumed.
      expect(await replayProjectedDeferredUpdates(db)).toEqual({ applied: 0, retained: 0 })
    },
  )
})
