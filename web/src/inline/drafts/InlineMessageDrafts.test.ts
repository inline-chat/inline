import {
  Db,
  DbObjectKind,
  messageDraftKey,
  type MessageDraft,
} from "@inline/client/core"
import { userId } from "@inline/ids"
import { describe, expect, it } from "vitest"
import type { CollectionStorage } from "@inline/client/core"
import { MessageEntity_Type } from "@inline-chat/protocol/core"
import { InlineMessageDrafts } from "./InlineMessageDrafts"

const peer = {
  peerKind: "user" as const,
  peerUserId: userId(42),
}

const namespace = () =>
  `message-draft-test-${crypto.randomUUID()}`

describe("InlineMessageDrafts", () => {
  it("persists and selectively restores one peer draft", async () => {
    const storageNamespace = namespace()
    const firstDb = new Db({
      autoHydrate: false,
      storageNamespace,
    })
    const first = new InlineMessageDrafts(firstDb)
    await first.update(peer, "hello\r\nworld", {
      entities: [
        {
          type: MessageEntity_Type.BOLD,
          offset: 0n,
          length: 5n,
          entity: { oneofKind: undefined },
        },
      ],
    })

    const secondDb = new Db({
      autoHydrate: false,
      storageNamespace,
    })
    const second = new InlineMessageDrafts(secondDb)
    const restored = await second.load(peer)

    expect(restored).toMatchObject({
      id: messageDraftKey(peer),
      peerKind: "user",
      peerUserId: userId(42),
      text: "hello\nworld",
      revision: 1,
      entities: {
        entities: [
          {
            type: MessageEntity_Type.BOLD,
            offset: 0n,
            length: 5n,
            entity: { oneofKind: undefined },
          },
        ],
      },
    })
  })

  it("treats whitespace-only text as a durable clear", async () => {
    const db = new Db({ autoHydrate: false })
    const drafts = new InlineMessageDrafts(db)
    await drafts.update(peer, "draft")
    await drafts.update(peer, " \n ")

    expect(
      db.get(
        db.ref(
          DbObjectKind.MessageDraft,
          messageDraftKey(peer),
        ),
      ),
    ).toBeUndefined()
  })

  it("serializes clear behind an in-flight save", async () => {
    const rows = new Map<string, MessageDraft>()
    let signalFirstPutStarted: (() => void) | undefined
    const firstPutStarted = new Promise<void>((resolve) => {
      signalFirstPutStarted = resolve
    })
    let finishFirstPut: (() => void) | undefined
    let firstPut = true
    const storage: CollectionStorage<MessageDraft> = {
      init: async () => undefined,
      get: async (id) => rows.get(id),
      getAll: async () => Array.from(rows.values()),
      put: async (draft) => {
        if (firstPut) {
          firstPut = false
          signalFirstPutStarted?.()
          await new Promise<void>((resolve) => {
            finishFirstPut = resolve
          })
        }
        rows.set(draft.id, draft)
      },
      delete: async (id) => {
        rows.delete(id)
      },
    }
    const db = new Db({
      autoHydrate: false,
      storageByKind: {
        [DbObjectKind.MessageDraft]: storage,
      },
    })
    const drafts = new InlineMessageDrafts(db)

    const save = drafts.update(peer, "stale")
    const clear = drafts.clear(peer)
    await firstPutStarted
    finishFirstPut?.()
    await Promise.all([save, clear])

    expect(rows.size).toBe(0)
    expect(await drafts.load(peer)).toBeUndefined()
  })

  it("does not rehydrate a stale row while its clear is committing", async () => {
    const id = messageDraftKey(peer)
    const rows = new Map<string, MessageDraft>([
      [
        id,
        {
          kind: DbObjectKind.MessageDraft,
          id,
          peerKind: "user",
          peerUserId: peer.peerUserId,
          text: "stale",
          revision: 1,
          updatedAt: 1,
        },
      ],
    ])
    let signalDeleteStarted: (() => void) | undefined
    const deleteStarted = new Promise<void>((resolve) => {
      signalDeleteStarted = resolve
    })
    let finishDelete: (() => void) | undefined
    const storage: CollectionStorage<MessageDraft> = {
      init: async () => undefined,
      get: async (key) => rows.get(key),
      getAll: async () => Array.from(rows.values()),
      put: async (draft) => {
        rows.set(draft.id, draft)
      },
      delete: async (key) => {
        signalDeleteStarted?.()
        await new Promise<void>((resolve) => {
          finishDelete = resolve
        })
        rows.delete(key)
      },
    }
    const db = new Db({
      autoHydrate: false,
      storageByKind: {
        [DbObjectKind.MessageDraft]: storage,
      },
    })
    const drafts = new InlineMessageDrafts(db)
    await drafts.load(peer)

    const clear = drafts.clear(peer)
    await deleteStarted
    const concurrentLoad = drafts.load(peer)
    finishDelete?.()

    await expect(clear).resolves.toBeUndefined()
    await expect(concurrentLoad).resolves.toBeUndefined()
    expect(db.get(db.ref(DbObjectKind.MessageDraft, id))).toBeUndefined()
  })
})
