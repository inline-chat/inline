import { Log } from "@inline/log"
import { parseInlineId } from "@inline/ids"
import type { Db } from "../database"
import {
  DbObjectKind,
  type ReservedChatID,
} from "../database/models"
import { DbQueryPlanType } from "../database/types"
import { reserveChatIds } from "./transactions/reserve-chat-ids"
import type { RealtimeService } from "./realtime-service"

type ReservationConsumer<T> = (
  reservation: ReservedChatID,
) => Promise<T>

export type ReservedChatIDConsumption<T> =
  | { consumed: true; value: T }
  | { consumed: false }

/**
 * Owner-only persisted pool matching InlineKit ReservedChatIDPool. Consumption
 * is serialized, while the consumer atomically claims the selected row in its
 * own durable create transaction.
 */
export class ReservedChatIDPool {
  private readonly lowWatermark = 1
  private readonly targetCount = 3
  private readonly log = new Log("ReservedChatIDPool")
  private hydrated = false
  private hydrateTask: Promise<void> | null = null
  private refillTask: Promise<void> | null = null
  private consumeQueue: Promise<void> = Promise.resolve()

  constructor(
    private readonly db: Db,
    private readonly realtime: Pick<RealtimeService, "mutate">,
  ) {}

  consumeCached<T>(
    consumer: ReservationConsumer<T>,
  ): Promise<ReservedChatIDConsumption<T>> {
    const operation = this.consumeQueue.then(async () => {
      await this.ensureHydrated()
      await this.pruneExpiredReservations()
      const reservation = this.oldestReservation()
      if (!reservation) return { consumed: false } as const
      const value = await consumer(reservation)
      return { consumed: true, value } as const
    })
    this.consumeQueue = operation.then(
      () => undefined,
      () => undefined,
    )
    const scheduleRefill = () => {
      void this.refillIfNeeded().catch((error: unknown) => {
        this.log.warn("Failed to refill reserved chat IDs", error)
      })
    }
    void operation.then(scheduleRefill, scheduleRefill)
    return operation
  }

  refillIfNeeded(): Promise<void> {
    if (this.refillTask) return this.refillTask
    const task = this.performRefill()
    this.refillTask = task
    const clearTask = () => {
      if (this.refillTask === task) this.refillTask = null
    }
    void task.then(clearTask, clearTask)
    return task
  }

  private async performRefill() {
    await this.ensureHydrated()
    await this.pruneExpiredReservations()
    const count = this.reservations().length
    if (count >= this.lowWatermark) return

    const requestedCount = this.targetCount - count
    const result = await this.realtime.mutate(
      reserveChatIds(requestedCount),
    )
    if (!result || result.oneofKind !== "reserveChatIds") {
      throw new Error("Inline returned an invalid reserved chat ID response")
    }

    const nowSeconds = Math.floor(Date.now() / 1_000)
    const createdAt = Date.now()
    const reservations = result.reserveChatIds.reservations.map(
      (value): ReservedChatID => {
        const exactChatID = parseInlineId<"chat">(value.chatId, {
          positive: true,
        })
        const expiresAt = Number(value.expiresAt)
        if (
          exactChatID == null ||
          !Number.isSafeInteger(expiresAt) ||
          expiresAt <= nowSeconds
        ) {
          throw new Error("Inline returned an invalid reserved chat ID")
        }
        return {
          kind: DbObjectKind.ReservedChatID,
          id: exactChatID,
          chatId: exactChatID,
          expiresAt,
          createdAt,
        }
      },
    )
    if (reservations.length === 0) {
      throw new Error("Inline returned no reserved chat IDs")
    }
    if (new Set(reservations.map((value) => value.chatId)).size !== reservations.length) {
      throw new Error("Inline returned duplicate reserved chat IDs")
    }

    await this.db.commit(() => {
      for (const reservation of reservations) {
        this.db.replace(reservation)
      }
    })
  }

  private ensureHydrated(): Promise<void> {
    if (this.hydrated) return Promise.resolve()
    if (!this.hydrateTask) {
      this.hydrateTask = this.db
        .hydrateKinds([DbObjectKind.ReservedChatID])
        .then(() => {
          this.hydrated = true
        })
        .finally(() => {
          this.hydrateTask = null
        })
    }
    return this.hydrateTask
  }

  private async pruneExpiredReservations() {
    const nowSeconds = Math.floor(Date.now() / 1_000)
    const expired = this.reservations().filter(
      (reservation) => reservation.expiresAt <= nowSeconds,
    )
    if (expired.length === 0) return
    await this.db.commit(() => {
      for (const reservation of expired) {
        this.db.delete(
          this.db.ref(DbObjectKind.ReservedChatID, reservation.id),
        )
      }
    })
  }

  private oldestReservation(): ReservedChatID | undefined {
    return this.reservations().sort(
      (left, right) =>
        left.createdAt - right.createdAt ||
        (BigInt(left.chatId) < BigInt(right.chatId) ? -1 : 1),
    )[0]
  }

  private reservations(): ReservedChatID[] {
    return this.db.queryCollection<
      DbObjectKind.ReservedChatID,
      ReservedChatID,
      DbQueryPlanType.Objects
    >(
      DbQueryPlanType.Objects,
      DbObjectKind.ReservedChatID,
      () => true,
    )
  }
}
