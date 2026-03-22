import { db } from "@in/server/db"
import { chatIdReservations } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { sql } from "drizzle-orm"
import type { ReserveChatIdsResult } from "@inline-chat/protocol/core"

const MAX_RESERVATION_COUNT = 10
const RESERVATION_TTL_MS = 7 * 24 * 60 * 60 * 1000

export async function reserveChatIds(
  input: { count: number },
  context: FunctionContext,
): Promise<ReserveChatIdsResult> {
  const count = Number(input.count)
  if (!Number.isInteger(count) || count <= 0 || count > MAX_RESERVATION_COUNT) {
    throw RealtimeRpcError.BadRequest()
  }

  const expiresAt = new Date(Date.now() + RESERVATION_TTL_MS)

  const reservations = await db.transaction(async (tx) => {
    const result = await tx.execute(sql<{ chatId: number }>`
      select nextval(pg_get_serial_sequence('chats', 'id'))::int as "chatId"
      from generate_series(1, ${count})
    `)

    const rows = result.map((row) => Number(row["chatId"]))

    await tx.insert(chatIdReservations).values(
      rows.map((chatId) => ({
        chatId,
        userId: context.currentUserId,
        expiresAt,
      })),
    )

    return rows
  })

  return {
    reservations: reservations.map((chatId) => ({
      chatId: BigInt(chatId),
      expiresAt: BigInt(Math.floor(expiresAt.getTime() / 1000)),
    })),
  }
}
