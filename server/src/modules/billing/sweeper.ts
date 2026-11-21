import { Log } from "@in/server/utils/log"
import { checkoutConfig, sweepBilling, syncSeats } from "./service"

const log = new Log("billing.sweeper")

const SWEEP_INTERVAL_MS = 10 * 60 * 1000
const SEAT_SYNC_INTERVAL_MS = 24 * 60 * 60 * 1000

let timer: ReturnType<typeof setInterval> | undefined
let inFlight: Promise<void> | undefined
let lastSeatSync = 0

const tick = async () => {
  const expired = await sweepBilling()
  if (expired) log.info("billing plans expired", { count: expired })
  if (checkoutConfig() && Date.now() - lastSeatSync >= SEAT_SYNC_INTERVAL_MS) {
    lastSeatSync = Date.now()
    const updated = await syncSeats()
    if (updated) log.info("billing seats synced", { count: updated })
  }
}

/** Expires lapsed plans and keeps per-seat quantities current. Idempotent across servers. */
export function startBillingSweeper(): void {
  if (timer) return
  timer = setInterval(() => {
    if (inFlight) return
    inFlight = tick()
      .catch((error: unknown) => log.warn("billing sweep failed", { error }))
      .finally(() => {
        inFlight = undefined
      })
  }, SWEEP_INTERVAL_MS)
  timer.unref?.()
}

export async function stopBillingSweeper(): Promise<void> {
  if (timer) clearInterval(timer)
  timer = undefined
  await inFlight
}
