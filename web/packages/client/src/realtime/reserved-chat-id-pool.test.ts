import type { RpcResult } from "@inline-chat/protocol/core"
import { chatId } from "@inline/ids"
import { describe, expect, it, vi } from "vitest"
import { Db } from "../database"
import {
  DbObjectKind,
  type ReservedChatID,
} from "../database/models"
import { DbQueryPlanType } from "../database/types"
import { ReservedChatIDPool } from "./reserved-chat-id-pool"

const reservations = (db: Db) =>
  db.queryCollection<
    DbObjectKind.ReservedChatID,
    ReservedChatID,
    DbQueryPlanType.Objects
  >(
    DbQueryPlanType.Objects,
    DbObjectKind.ReservedChatID,
    () => true,
  )

describe("ReservedChatIDPool", () => {
  it("refills to InlineKit's target and consumes the oldest row through its caller", async () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    const now = Math.floor(Date.now() / 1_000)
    const mutate = vi.fn(async (): Promise<RpcResult["result"]> => ({
      oneofKind: "reserveChatIds",
      reserveChatIds: {
        reservations: [
          { chatId: 903n, expiresAt: BigInt(now + 300) },
          { chatId: 901n, expiresAt: BigInt(now + 300) },
          { chatId: 902n, expiresAt: BigInt(now + 300) },
        ],
      },
    }))
    const pool = new ReservedChatIDPool(db, { mutate })

    await pool.refillIfNeeded()
    expect(mutate).toHaveBeenCalledOnce()
    expect(reservations(db)).toHaveLength(3)

    const consumption = await pool.consumeCached(async (reservation) => {
      await db.commit(() => {
        db.delete(
          db.ref(DbObjectKind.ReservedChatID, reservation.id),
        )
      })
      return reservation.chatId
    })
    expect(consumption).toEqual({
      consumed: true,
      value: chatId(901),
    })
    expect(reservations(db).map((value) => value.chatId)).toEqual([
      chatId(903),
      chatId(902),
    ])
    expect(mutate).toHaveBeenCalledOnce()
  })

  it("prunes expired rows before deciding whether to refill", async () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    const now = Math.floor(Date.now() / 1_000)
    db.insert({
      kind: DbObjectKind.ReservedChatID,
      id: chatId(700),
      chatId: chatId(700),
      expiresAt: now,
      createdAt: 1,
    })
    const mutate = vi.fn(async (): Promise<RpcResult["result"]> => ({
      oneofKind: "reserveChatIds",
      reserveChatIds: {
        reservations: [
          { chatId: 701n, expiresAt: BigInt(now + 300) },
        ],
      },
    }))
    const pool = new ReservedChatIDPool(db, { mutate })

    await pool.refillIfNeeded()
    expect(reservations(db)).toMatchObject([
      { chatId: chatId(701) },
    ])
  })

  it("rejects a malformed allocation without poisoning the local pool", async () => {
    const db = new Db({ autoHydrate: false, persistence: false })
    const now = Math.floor(Date.now() / 1_000)
    const pool = new ReservedChatIDPool(db, {
      mutate: async () => ({
        oneofKind: "reserveChatIds",
        reserveChatIds: {
          reservations: [
            { chatId: 701n, expiresAt: BigInt(now + 300) },
            { chatId: 701n, expiresAt: BigInt(now + 300) },
          ],
        },
      }),
    })

    await expect(pool.refillIfNeeded()).rejects.toThrow(
      "duplicate reserved chat IDs",
    )
    expect(reservations(db)).toEqual([])
  })
})
