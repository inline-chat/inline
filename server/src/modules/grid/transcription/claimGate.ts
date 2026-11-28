import { onGridChanged } from "@in/server/modules/grid/realtime"

/**
 * Idle transcription workers poll `claim` every couple of seconds per slot, and
 * almost every poll finds nothing. Once a poll sees no run in `starting` or
 * `stopping`, this node answers later polls from memory until a Grid change
 * lands (here or hinted from another node) or the backstop passes.
 *
 * Every committed transition that creates claim work (starting a run, asking a
 * claimed run to stop) announces a Grid change after commit. The backstop
 * covers dropped hints and writes made outside the app.
 */
export const GRID_CLAIM_IDLE_BACKSTOP_MS = 10_000

let generation = 0
let idleUntil = 0

onGridChanged(() => {
  generation += 1
  idleUntil = 0
})

/** True while a recent poll proved there is nothing to claim and nothing changed since. */
export function gridClaimKnownIdle(now = Date.now()): boolean {
  return now < idleUntil
}

/** Read before the scan; a change that commits during the scan voids its result. */
export function gridClaimGeneration(): number {
  return generation
}

export function markGridClaimIdle(scanGeneration: number, now = Date.now()) {
  if (scanGeneration !== generation) return
  idleUntil = now + GRID_CLAIM_IDLE_BACKSTOP_MS
}

export function resetGridClaimGate() {
  generation += 1
  idleUntil = 0
}
