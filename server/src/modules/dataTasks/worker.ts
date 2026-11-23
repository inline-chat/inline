import { Log } from "@in/server/utils/log"
import { runPendingDataTasks } from "./automatic"

const log = new Log("dataTasks.worker")

/** After boot, so a deploy settles and readiness passes first. */
const FIRST_RUN_DELAY_MS = 2 * 60 * 1000
/** Retries blocked, failed or paused runs, and picks up a stale lease. */
const RUN_INTERVAL_MS = 60 * 60 * 1000

let firstRun: ReturnType<typeof setTimeout> | undefined
let interval: ReturnType<typeof setInterval> | undefined
let inFlight: Promise<void> | undefined
let stopping = false

const tick = () => {
  if (inFlight || stopping) return
  inFlight = runPendingDataTasks({ shouldStop: () => stopping, sourceCommit: process.env["SOURCE_COMMIT"] })
    .then(() => undefined)
    .catch((error: unknown) => log.error("data task tick failed", error))
    .finally(() => {
      inFlight = undefined
    })
}

/** Runs pending data tasks on the worker process, like migrations run on deploy. */
export function startDataTaskWorker(): void {
  if (firstRun || interval) return
  stopping = false
  firstRun = setTimeout(tick, FIRST_RUN_DELAY_MS)
  interval = setInterval(tick, RUN_INTERVAL_MS)
  firstRun.unref?.()
  interval.unref?.()
}

/** Pauses a run between items; it resumes from the ledger on the next start. */
export async function stopDataTaskWorker(): Promise<void> {
  stopping = true
  if (firstRun) clearTimeout(firstRun)
  if (interval) clearInterval(interval)
  firstRun = undefined
  interval = undefined
  await inFlight
}
