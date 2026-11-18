import {
  GetUpdatesResult_ResultType,
  Method,
  Update,
  type RpcCall,
  type RpcResult,
} from "@inline-chat/protocol/core"
import { chatId, inlineId, spaceId, userId, type UserID } from "@inline/ids"
import { Db } from "../../database"
import { DbObjectKind } from "../../database/models"
import type { InlinePersistenceStore } from "../../database/persistence"
import { DbQueryPlanType } from "../../database/types"
import { SyncEngine, type SyncRpcClient } from "../sync/sync-engine"
import { syncBucketId, type SyncBucketKey } from "../sync/sync-types"
import { getDialogId } from "../transactions/mappers"
import { bindAccountUser } from "../updates/account-context"

/*
 * Shared fixtures for the update-coverage tests: a small account (self is
 * user 1), a sync client that serves per-bucket journals, and observers that
 * read the projected state as plain data.
 */

export const SELF = userId(1)
export const SPACE = spaceId(5)
/** A private thread in the space. */
export const THREAD = chatId(10)
/** A public thread in the space. */
export const PUBLIC_THREAD = chatId(11)
/** A thread outside any space. */
export const LOOSE_THREAD = chatId(12)
/** A direct message with user 2. */
export const DM = chatId(13)
export const GROUP = inlineId(30)

export const chatPeer = (id: bigint) => ({
  type: { oneofKind: "chat" as const, chat: { chatId: id } },
})

export const update = (
  seq: number,
  payload: Update["update"],
  date = 1_000 + seq,
) => Update.create({ seq, date: BigInt(date), update: payload })

/** Write the account's starting state straight into the store. */
export const seedAccount = (db: Db, self: UserID = SELF) => {
  bindAccountUser(db, () => self)
  db.batch(() => {
    for (const id of [1, 2, 3, 4]) {
      db.replace({ kind: DbObjectKind.User, id: userId(id), firstName: `User ${id}` })
    }
    db.replace({
      kind: DbObjectKind.Space,
      id: SPACE,
      name: "Space",
      creator: false,
      date: 100,
    })
    const thread = (id: typeof THREAD, extra: object = {}) => {
      db.replace({ kind: DbObjectKind.Chat, id, title: `Chat ${id}`, ...extra })
      db.replace({
        kind: DbObjectKind.Dialog,
        id: getDialogId({ peerThreadId: id }),
        chatId: id,
        peerThreadId: id,
        ...("spaceId" in extra ? { spaceId: SPACE } : {}),
      })
    }
    thread(THREAD, { spaceId: SPACE })
    thread(PUBLIC_THREAD, { spaceId: SPACE, isPublic: true })
    thread(LOOSE_THREAD)
    db.replace({ kind: DbObjectKind.Chat, id: DM, title: "DM", peerUserId: userId(2) })
    db.replace({
      kind: DbObjectKind.Dialog,
      id: getDialogId({ peerUserId: userId(2) }),
      chatId: DM,
      peerUserId: userId(2),
    })
    db.replace({
      kind: DbObjectKind.UserGroup,
      id: GROUP,
      spaceId: SPACE,
      name: "Design",
      memberCount: 2,
      userIds: [SELF, userId(3)],
      currentUserIsMember: true,
      date: 100,
    })
  })
}

const sortById = <T extends { id: unknown }>(rows: T[]) =>
  rows.slice().sort((left, right) => String(left.id).localeCompare(String(right.id)))

/** Everything the update-coverage kinds project, as plain data. */
export const observe = (db: Db) => {
  const all = <K extends DbObjectKind>(kind: K) =>
    sortById(db.queryCollection(DbQueryPlanType.Objects, kind))
  return {
    spaces: all(DbObjectKind.Space),
    chats: all(DbObjectKind.Chat),
    dialogs: all(DbObjectKind.Dialog),
    members: all(DbObjectKind.SpaceMember),
    participants: all(DbObjectKind.ChatParticipant),
    grants: all(DbObjectKind.ChatParticipantGroup),
    groups: all(DbObjectKind.UserGroup),
    folders: all(DbObjectKind.DialogFolder),
    settings: all(DbObjectKind.UserSettings),
    users: all(DbObjectKind.User),
  }
}

/** The same projection read back from SQLite. */
export const observeStored = async (store: InlinePersistenceStore) => {
  const all = async <K extends DbObjectKind>(kind: K) =>
    sortById(await store.collection(kind).getAll())
  return {
    spaces: await all(DbObjectKind.Space),
    chats: await all(DbObjectKind.Chat),
    dialogs: await all(DbObjectKind.Dialog),
    members: await all(DbObjectKind.SpaceMember),
    participants: await all(DbObjectKind.ChatParticipant),
    grants: await all(DbObjectKind.ChatParticipantGroup),
    groups: await all(DbObjectKind.UserGroup),
    folders: await all(DbObjectKind.DialogFolder),
    settings: await all(DbObjectKind.UserSettings),
    users: await all(DbObjectKind.User),
  }
}

const emptyPage = (seq: bigint): RpcResult["result"] => ({
  oneofKind: "getUpdates",
  getUpdates: {
    updates: [],
    seq,
    date: 0n,
    final: true,
    resultType: GetUpdatesResult_ResultType.EMPTY,
    skippedSequences: [],
  },
})

/**
 * A server end that serves one journal per bucket. Only the first
 * `published` records of a journal exist yet, so a test can push a later
 * record live (a gap) before the server has served the earlier ones.
 */
export class JournalClient implements SyncRpcClient {
  readonly calls: Array<{ method: Method; input: RpcCall["input"] }> = []
  readonly journals = new Map<string, Update[]>()
  readonly published = new Map<string, number>()

  journal(key: SyncBucketKey, updates: Update[]) {
    this.journals.set(syncBucketId(key), updates)
    this.published.set(syncBucketId(key), 0)
  }

  publish(key: SyncBucketKey, count: number) {
    this.published.set(syncBucketId(key), count)
  }

  async callRpc(method: Method, input: RpcCall["input"]) {
    this.calls.push({ method, input })
    if (method === Method.GET_UPDATES_STATE) {
      return {
        oneofKind: "getUpdatesState" as const,
        getUpdatesState: { date: 2_000n, updatesFound: false },
      }
    }
    if (input.oneofKind !== "getUpdates") {
      throw new Error(`unexpected method ${method}`)
    }
    const type = input.getUpdates.bucket?.type
    const key: SyncBucketKey | undefined =
      type?.oneofKind === "user"
        ? { kind: "user" }
        : type?.oneofKind === "space"
          ? { kind: "space", spaceId: spaceId(type.space.spaceId) }
          : type?.oneofKind === "chat" && type.chat.peerId?.type.oneofKind === "chat"
            ? { kind: "chat", peer: chatPeer(type.chat.peerId.type.chat.chatId) }
            : undefined
    const start = Number(input.getUpdates.startSeq ?? 0n)
    if (!key) return emptyPage(BigInt(start))
    const id = syncBucketId(key)
    const visible = (this.journals.get(id) ?? []).slice(0, this.published.get(id) ?? 0)
    const end = input.getUpdates.seqEnd && input.getUpdates.seqEnd > 0n
      ? Number(input.getUpdates.seqEnd)
      : visible.length
    const page = visible.filter((entry) => (entry.seq ?? 0) > start && (entry.seq ?? 0) <= end)
    if (page.length === 0) return emptyPage(BigInt(start))
    const last = page[page.length - 1]!
    return {
      oneofKind: "getUpdates" as const,
      getUpdates: {
        updates: page,
        seq: BigInt(last.seq ?? start),
        date: last.date ?? 0n,
        final: (last.seq ?? 0) >= visible.length,
        resultType: GetUpdatesResult_ResultType.SLICE,
        skippedSequences: [],
      },
    }
  }
}

export const createSyncEngine = (db: Db, client: SyncRpcClient) =>
  new SyncEngine({ db, client, now: () => 10_000, retryDelaysMs: [60_000] })
