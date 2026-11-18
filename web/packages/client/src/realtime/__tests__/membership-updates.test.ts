import { Member_Role, Method, type RpcCall, type RpcResult } from "@inline-chat/protocol/core"
import { chatId, messageId, spaceId, userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import { Db } from "../../database"
import {
  chatParticipantKey,
  DbObjectKind,
  messageKey,
  spaceMemberKey,
} from "../../database/models"
import { createSqliteMemoryPersistenceStore } from "../../database/sqlite/openers"
import { DbQueryPlanType } from "../../database/types"
import { syncBucketId } from "../sync/sync-types"
import { getDialogId } from "../transactions/mappers"
import { getChatParticipants } from "../transactions/get-chat-participants"
import { getSpaceMembers } from "../transactions/get-space-members"
import { applyUpdates } from "../updates/apply-updates"
import {
  chatPeer,
  createSyncEngine,
  DM,
  GROUP,
  JournalClient,
  LOOSE_THREAD,
  PUBLIC_THREAD,
  SPACE,
  seedAccount,
  THREAD,
  update,
} from "./update-coverage-fixtures"

const member = (id: bigint, user: bigint, extra: object = {}) => ({
  id,
  spaceId: 5n,
  userId: user,
  role: Member_Role.MEMBER,
  date: 1_000n,
  canAccessPublicChats: true,
  ...extra,
})

const memberRow = (db: Db, user: number) =>
  db.get(db.ref(DbObjectKind.SpaceMember, spaceMemberKey(SPACE, userId(user))))

const participantRow = (db: Db, chat = THREAD, user = 1) =>
  db.get(db.ref(DbObjectKind.ChatParticipant, chatParticipantKey(chat, userId(user))))

const seeded = () => {
  const db = new Db({ autoHydrate: false })
  seedAccount(db)
  return db
}

/** Messages, a draft, coverage, grants and a cursor for one chat. */
const fillChat = (db: Db, chat = THREAD) => {
  db.batch(() => {
    db.replace({
      kind: DbObjectKind.Message,
      id: messageKey(chat, messageId(1)),
      messageId: messageId(1),
      chatId: chat,
      fromId: userId(2),
      message: "hello",
      date: 1_000,
    })
    db.replace({
      kind: DbObjectKind.MessageDraft,
      id: `chat:${chat}`,
      peerKind: "chat",
      peerThreadId: chat,
      text: "unsent",
      revision: 1,
      updatedAt: 1,
    })
    db.replace({
      kind: DbObjectKind.HistoryCoverage,
      id: chat,
      ranges: [[messageId(1), messageId(1)]],
    })
    db.replace({
      kind: DbObjectKind.ChatParticipant,
      id: chatParticipantKey(chat, userId(1)),
      chatId: chat,
      userId: userId(1),
      date: 1,
    })
    db.replace({
      kind: DbObjectKind.SyncBucketState,
      id: syncBucketId({ kind: "chat", peer: chatPeer(BigInt(chat)) }),
      seq: 4,
      date: 1,
    })
  })
}

const expectPurged = (db: Db, chat = THREAD) => {
  expect(db.get(db.ref(DbObjectKind.Chat, chat))).toBeUndefined()
  expect(
    db.get(db.ref(DbObjectKind.Dialog, getDialogId({ peerThreadId: chat }))),
  ).toBeUndefined()
  expect(
    db.get(db.ref(DbObjectKind.Message, messageKey(chat, messageId(1)))),
  ).toBeUndefined()
  expect(db.historyCoverage(chat)).toEqual([])
  expect(
    db.queryCollection(
      DbQueryPlanType.Objects,
      DbObjectKind.ChatParticipant,
      (row) => row.chatId === chat,
    ),
  ).toEqual([])
  expect(
    db.get(
      db.ref(
        DbObjectKind.SyncBucketState,
        syncBucketId({ kind: "chat", peer: chatPeer(BigInt(chat)) }),
      ),
    ),
  ).toBeUndefined()
  // Drafts are kept (core.md, "Sync").
  expect(db.get(db.ref(DbObjectKind.MessageDraft, `chat:${chat}`))?.text).toBe("unsent")
}

describe("space members", () => {
  it("keeps the later membership generation against delayed events", () => {
    const db = seeded()
    applyUpdates(db, [
      update(1, { oneofKind: "spaceMemberAdd", spaceMemberAdd: { member: member(102n, 3n) } }),
      // An add of an older generation arrives late: ignored.
      update(2, { oneofKind: "spaceMemberAdd", spaceMemberAdd: { member: member(101n, 3n) } }),
      // A removal of that older generation: ignored.
      update(3, {
        oneofKind: "spaceMemberDelete",
        spaceMemberDelete: { spaceId: 5n, userId: 3n, memberId: 101n },
      }),
    ])
    expect(memberRow(db, 3)?.memberId).toBe("102")

    // Without a member ID, an event older than the join date proves the same.
    applyUpdates(db, [
      update(4, { oneofKind: "spaceMemberDelete", spaceMemberDelete: { spaceId: 5n, userId: 3n } }, 900),
    ])
    expect(memberRow(db, 3)?.memberId).toBe("102")
    applyUpdates(db, [
      update(5, { oneofKind: "spaceMemberDelete", spaceMemberDelete: { spaceId: 5n, userId: 3n } }, 1_100),
    ])
    expect(memberRow(db, 3)).toBeUndefined()
  })

  it("skips member events a roster snapshot already covers, and replaces the roster", () => {
    const db = seeded()
    applyUpdates(db, [
      update(1, { oneofKind: "spaceMemberAdd", spaceMemberAdd: { member: member(90n, 4n) } }),
    ])
    getSpaceMembers({ spaceId: SPACE }).apply(
      {
        oneofKind: "getSpaceMembers",
        getSpaceMembers: {
          members: [member(100n, 3n)],
          users: [{ id: 3n, firstName: "Three" }],
          seq: 10,
        },
      },
      db,
    )
    // The roster replaced the stored members.
    expect(memberRow(db, 4)).toBeUndefined()
    expect(db.get(db.ref(DbObjectKind.Space, SPACE))).toMatchObject({
      memberRosterSeq: 10,
      memberRosterComplete: true,
    })
    applyUpdates(db, [
      update(9, { oneofKind: "spaceMemberAdd", spaceMemberAdd: { member: member(91n, 2n) } }),
      update(10, {
        oneofKind: "spaceMemberDelete",
        spaceMemberDelete: { spaceId: 5n, userId: 3n, memberId: 100n },
      }),
    ])
    expect(memberRow(db, 2)).toBeUndefined()
    expect(memberRow(db, 3)?.memberId).toBe("100")
    applyUpdates(db, [
      update(11, { oneofKind: "spaceMemberAdd", spaceMemberAdd: { member: member(92n, 2n) } }),
    ])
    expect(memberRow(db, 2)?.memberId).toBe("92")
  })

  it("joinSpace restores a missing membership but keeps a stored one", () => {
    const db = seeded()
    const join = (role: Member_Role) =>
      update(1, {
        oneofKind: "joinSpace",
        joinSpace: {
          space: { id: 5n, name: "Space", creator: false, date: 100n },
          member: member(70n, 1n, { role }),
        },
      })
    applyUpdates(db, [join(Member_Role.MEMBER)])
    expect(memberRow(db, 1)?.role).toBe("member")
    applyUpdates(db, [
      update(2, {
        oneofKind: "spaceMemberUpdate",
        spaceMemberUpdate: { member: member(70n, 1n, { role: Member_Role.ADMIN }) },
      }),
    ])
    // The user journal replays the join with its old role: kept as is.
    applyUpdates(db, [join(Member_Role.MEMBER)])
    expect(memberRow(db, 1)?.role).toBe("admin")
  })
})

describe("chat participants", () => {
  it("stores a grant only when its chat is local, and marks the roster incomplete when its user or group is not", () => {
    const db = seeded()
    applyUpdates(db, [
      update(1, {
        oneofKind: "participantAdd",
        participantAdd: { chatId: 99n, participant: { userId: 3n, date: 1n } },
      }),
      update(2, {
        oneofKind: "participantAdd",
        participantAdd: { chatId: 10n, participant: { userId: 77n, date: 1n } },
      }),
    ])
    expect(db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.ChatParticipant)).toEqual([])
    expect(db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.DeferredUpdate)).toEqual([])
    expect(db.get(db.ref(DbObjectKind.Chat, THREAD))?.participantRosterComplete).toBe(false)

    getChatParticipants({ chatId: THREAD }).apply(
      {
        oneofKind: "getChatParticipants",
        getChatParticipants: {
          participants: [{ userId: 77n, date: 2n }],
          users: [{ id: 77n, firstName: "New" }],
          groupParticipants: [{ groupId: 31n, date: 3n }],
          groups: [
            { id: 31n, spaceId: 5n, name: "Ops", memberCount: 1, userIds: [77n], currentUserIsMember: false, date: 3n },
          ],
        },
      },
      db,
    )
    expect(participantRow(db, THREAD, 77)).toMatchObject({ date: 2 })
    expect(
      db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.ChatParticipantGroup).map((row) => row.id),
    ).toEqual(["10:31"])
    expect(db.get(db.ref(DbObjectKind.Chat, THREAD))?.participantRosterComplete).toBe(true)
  })
})

describe("access loss purges in one write and keeps drafts", () => {
  it("userRemovedFromChat purges the chat and everything under it in one commit", async () => {
    const store = createSqliteMemoryPersistenceStore()
    const db = new Db({ autoHydrate: false, persistenceStore: store })
    seedAccount(db)
    fillChat(db)
    await db.flushPersistence()
    const batches: number[] = []
    db.subscribeToResidentChanges((batch) => batches.push(batch.changes.length))

    await db.commit(() => {
      applyUpdates(db, [
        update(1, { oneofKind: "userRemovedFromChat", userRemovedFromChat: { chatId: 10n } }),
      ])
    })
    expectPurged(db)
    // One committed batch carries the whole purge.
    expect(batches).toHaveLength(1)
    expect(await store.collection(DbObjectKind.Chat).get(THREAD)).toBeUndefined()
    expect(await store.collection(DbObjectKind.Message).getAll()).toEqual([])
    expect(await store.collection(DbObjectKind.ChatParticipant).getAll()).toEqual([])
    expect((await store.collection(DbObjectKind.MessageDraft).getAll()).map((row) => row.text)).toEqual([
      "unsent",
    ])
  })

  it("the account's own participantDelete purges a private thread it no longer reaches", () => {
    const db = seeded()
    fillChat(db)
    applyUpdates(db, [
      update(1, { oneofKind: "participantDelete", participantDelete: { chatId: 10n, userId: 1n } }),
    ])
    expectPurged(db)
  })

  it("keeps the thread while a group grant still includes the account", () => {
    const db = seeded()
    fillChat(db)
    db.replace({
      kind: DbObjectKind.ChatParticipantGroup,
      id: `${THREAD}:${GROUP}`,
      chatId: THREAD,
      groupId: GROUP,
      date: 1,
    })
    applyUpdates(db, [
      update(1, { oneofKind: "participantDelete", participantDelete: { chatId: 10n, userId: 1n } }),
    ])
    expect(db.get(db.ref(DbObjectKind.Chat, THREAD))).toBeDefined()

    // Losing that last grant purges it.
    applyUpdates(db, [
      update(2, {
        oneofKind: "participantGroupDelete",
        participantGroupDelete: { chatId: 10n, groupId: 30n },
      }),
    ])
    expectPurged(db)
  })

  it("does not purge when a later update in the same page grants access again", () => {
    const db = seeded()
    fillChat(db)
    applyUpdates(db, [
      update(1, { oneofKind: "participantDelete", participantDelete: { chatId: 10n, userId: 1n } }),
      update(2, {
        oneofKind: "userAddedToChat",
        userAddedToChat: { chatId: 10n, participant: { userId: 1n, date: 5n } },
      }),
    ])
    expect(db.get(db.ref(DbObjectKind.Chat, THREAD))).toBeDefined()
    expect(participantRow(db)?.date).toBe(5)
  })

  it("never purges a public thread or a direct message for a participant removal", () => {
    const db = seeded()
    applyUpdates(db, [
      update(1, { oneofKind: "participantDelete", participantDelete: { chatId: 11n, userId: 1n } }),
      update(2, { oneofKind: "participantDelete", participantDelete: { chatId: 13n, userId: 1n } }),
    ])
    expect(db.get(db.ref(DbObjectKind.Chat, PUBLIC_THREAD))).toBeDefined()
    expect(db.get(db.ref(DbObjectKind.Chat, DM))).toBeDefined()
  })

  it("the account's own spaceMemberDelete purges the space, its chats, members and groups", async () => {
    const store = createSqliteMemoryPersistenceStore()
    const db = new Db({ autoHydrate: false, persistenceStore: store })
    seedAccount(db)
    fillChat(db)
    fillChat(db, LOOSE_THREAD)
    applyUpdates(db, [
      update(1, { oneofKind: "spaceMemberAdd", spaceMemberAdd: { member: member(70n, 1n) } }),
      update(2, { oneofKind: "spaceMemberAdd", spaceMemberAdd: { member: member(71n, 3n) } }),
    ])
    db.replace({
      kind: DbObjectKind.SyncBucketState,
      id: syncBucketId({ kind: "space", spaceId: SPACE }),
      seq: 2,
      date: 1,
    })
    await db.flushPersistence()

    await db.commit(() => {
      applyUpdates(db, [
        update(3, {
          oneofKind: "spaceMemberDelete",
          spaceMemberDelete: { spaceId: 5n, userId: 1n, memberId: 70n },
        }),
      ])
    })
    expectPurged(db, THREAD)
    expect(db.get(db.ref(DbObjectKind.Chat, PUBLIC_THREAD))).toBeUndefined()
    expect(db.get(db.ref(DbObjectKind.Space, SPACE))).toBeUndefined()
    expect(db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.SpaceMember)).toEqual([])
    expect(db.queryCollection(DbQueryPlanType.Objects, DbObjectKind.UserGroup)).toEqual([])
    expect(
      db.get(db.ref(DbObjectKind.SyncBucketState, syncBucketId({ kind: "space", spaceId: SPACE }))),
    ).toBeUndefined()
    // Outside the space nothing changes.
    expect(db.get(db.ref(DbObjectKind.Chat, LOOSE_THREAD))).toBeDefined()
    expect(db.get(db.ref(DbObjectKind.Chat, DM))).toBeDefined()
    expect(await store.collection(DbObjectKind.Space).getAll()).toEqual([])
    expect(await store.collection(DbObjectKind.SpaceMember).getAll()).toEqual([])
    expect((await store.collection(DbObjectKind.MessageDraft).getAll()).length).toBe(2)
  })

  it("losing public-chat access purges the space's public threads only", () => {
    const db = seeded()
    applyUpdates(db, [
      update(1, { oneofKind: "spaceMemberAdd", spaceMemberAdd: { member: member(70n, 1n) } }),
      update(2, {
        oneofKind: "spaceMemberUpdate",
        spaceMemberUpdate: { member: member(70n, 1n, { canAccessPublicChats: false }) },
      }),
    ])
    expect(db.get(db.ref(DbObjectKind.Chat, PUBLIC_THREAD))).toBeUndefined()
    expect(db.get(db.ref(DbObjectKind.Chat, THREAD))).toBeDefined()
  })

  it("deleteChat purges the same way and keeps the draft", () => {
    const db = seeded()
    fillChat(db)
    applyUpdates(db, [
      update(1, { oneofKind: "deleteChat", deleteChat: { peerId: chatPeer(10n) } }),
    ])
    expectPurged(db)
  })
})

/** A client whose chat-bucket fetch waits until the test releases it. */
class GatedClient extends JournalClient {
  release!: () => void
  readonly gate = new Promise<void>((resolve) => {
    this.release = resolve
  })
  requested = false

  override async callRpc(method: Method, input: RpcCall["input"]): Promise<RpcResult["result"]> {
    if (
      input.oneofKind === "getUpdates" &&
      input.getUpdates.bucket?.type.oneofKind === "chat"
    ) {
      this.requested = true
      await this.gate
    }
    return super.callRpc(method, input)
  }
}

describe("a page in flight for a purged chat is fenced", () => {
  it("drops the page, writes no cursor and does not retry", async () => {
    const db = new Db({ autoHydrate: false })
    seedAccount(db)
    fillChat(db)
    const client = new GatedClient()
    const chatKey = { kind: "chat", peer: chatPeer(10n) } as const
    client.journal(chatKey, [
      update(5, {
        oneofKind: "newMessage",
        newMessage: {
          message: {
            id: 2n,
            chatId: 10n,
            peerId: chatPeer(10n),
            fromId: 2n,
            out: false,
            date: 1_005n,
            message: "after removal",
          },
        },
      }),
    ])
    client.publish(chatKey, 1)
    // Serve the page as if its sequence were 5 (the cursor is at 4).
    const journal = client.journals.get(syncBucketId(chatKey))!
    client.journals.set(syncBucketId(chatKey), [
      ...[1, 2, 3, 4].map((seq) => update(seq, { oneofKind: "chatSkipPts", chatSkipPts: { chatId: 10n } })),
      ...journal,
    ])
    client.publish(chatKey, 5)

    const engine = createSyncEngine(db, client)
    await engine.connectionOpened()
    await engine.idle()
    const pushed = engine.processPush([
      update(0, {
        oneofKind: "chatHasNewUpdates",
        chatHasNewUpdates: { chatId: 10n, peerId: chatPeer(10n), updateSeq: 5 },
      }),
    ])
    await pushed
    while (!client.requested) await new Promise((resolve) => setImmediate(resolve))

    // Access is lost while the page is in flight.
    await db.commit(() => {
      applyUpdates(db, [
        update(1, { oneofKind: "userRemovedFromChat", userRemovedFromChat: { chatId: 10n } }),
      ])
    })
    client.release()
    await engine.idle()

    expectPurged(db)
    expect(db.get(db.ref(DbObjectKind.Message, messageKey(chatId(10), messageId(2))))).toBeUndefined()
    const calls = client.calls.length
    await engine.idle()
    expect(client.calls.length).toBe(calls)
    expect(engine.stalledBuckets()).toEqual([])
    await engine.stop()

    // Storing the chat again lifts the fence.
    db.replace({ kind: DbObjectKind.Chat, id: THREAD, title: "Back", spaceId: spaceId(5) })
    expect(db.get(db.ref(DbObjectKind.Chat, THREAD))?.title).toBe("Back")
  })
})
