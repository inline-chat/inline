import {
  DbObjectKind,
  DbQueryPlanType,
} from "@inline/client"
import { chatId, userId } from "@inline/ids"
import { describe, expect, it, vi } from "vitest"
import { InlineProjectionDb } from "./InlineProjectionDb"

const makeDb = () => {
  const requestResync = vi.fn()
  return {
    db: new InlineProjectionDb({
      hydrateMessageWindow: async () => 0,
      loadLocalWindowAroundMessage: async () => false,
      requestResync,
    }),
    requestResync,
  }
}

describe("InlineProjectionDb", () => {
  it("never opens IndexedDB while applying renderer projections", async () => {
    const open = vi.spyOn(indexedDB, "open")
    const { db } = makeDb()

    db.applyProjection({
      revision: 1,
      messageWindowKeys: [],
      objects: [
        {
          kind: DbObjectKind.User,
          id: userId(7),
          firstName: "Mo",
        },
      ],
    })
    await db.flushPersistence()

    expect(open).not.toHaveBeenCalled()
  })

  it("replaces its resident projection from a snapshot", () => {
    const { db } = makeDb()
    db.applyProjection({
      revision: 4,
      messageWindowKeys: [],
      objects: [
        {
          kind: DbObjectKind.User,
          id: userId(7),
          firstName: "Mo",
        },
      ],
    })

    expect(
      db.get(db.ref(DbObjectKind.User, userId(7)))
        ?.firstName,
    ).toBe("Mo")
    expect(db.getProjectionRevision()).toBe(4)
  })

  it("applies ordered changes and tombstones", () => {
    const { db } = makeDb()
    db.applyProjection({
      revision: 1,
      objects: [],
      messageWindowKeys: [],
    })
    expect(
      db.applyChanges({
        revision: 2,
        messageWindowKeys: [],
        changes: [
          {
            kind: DbObjectKind.User,
            id: userId(7),
            object: {
              kind: DbObjectKind.User,
              id: userId(7),
              firstName: "Mo",
            },
          },
        ],
      }),
    ).toBe(true)
    expect(
      db.applyChanges({
        revision: 3,
        messageWindowKeys: [],
        changes: [
          {
            kind: DbObjectKind.User,
            id: userId(7),
          },
        ],
      }),
    ).toBe(true)

    expect(
      db.queryCollection(
        DbQueryPlanType.Objects,
        DbObjectKind.User,
      ),
    ).toEqual([])
  })

  it("refuses owner-only reservation rows in snapshots and change batches", () => {
    const { db } = makeDb()
    const reservedChatId = chatId(901)
    const object = {
      kind: DbObjectKind.ReservedChatID as const,
      id: reservedChatId,
      chatId: reservedChatId,
      expiresAt: 1_800_000_000,
      createdAt: 1_700_000_000_000,
    }
    db.applyProjection({
      revision: 1,
      messageWindowKeys: [],
      objects: [object],
    })
    db.applyChanges({
      revision: 2,
      messageWindowKeys: [],
      changes: [
        {
          kind: DbObjectKind.ReservedChatID,
          id: reservedChatId,
          object,
        },
      ],
    })

    expect(
      db.get(db.ref(DbObjectKind.ReservedChatID, reservedChatId)),
    ).toBeUndefined()
  })

  it("refuses an out-of-order batch and requests resync", () => {
    const { db, requestResync } = makeDb()
    db.applyProjection({
      revision: 2,
      objects: [],
      messageWindowKeys: [],
    })

    expect(
      db.applyChanges({
        revision: 4,
        messageWindowKeys: [],
        changes: [],
      }),
    ).toBe(false)
    expect(requestResync).toHaveBeenCalledOnce()
    expect(db.getProjectionRevision()).toBe(2)
  })
})
