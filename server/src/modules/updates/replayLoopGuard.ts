type ReplayState = {
  lastStart: number
  highWater: number
  rewinds: number
  /** Consecutive requests for the same start after a page that carried records. */
  repeats: number
  /** Whether the last served page for `lastStart` carried database records. */
  lastServedRecords: boolean
  blockedUntil: number
  touchedAt: number
}

/** Identical non-empty pages a client may re-request before it is slowed. A page
 * retry after a dropped response is normal; a third identical fetch is a client
 * that cannot apply what it received. */
const REPEAT_ALLOWANCE = 2
const REPEAT_BACKOFF_MS = 60_000
const REPEAT_BACKOFF_MAX_MS = 1_800_000

/** Bounds repeated large catch-up rewinds and repeated identical non-empty pages
 * on one session without discarding history. New forward progress, an empty
 * poll, and idle expiry remain available; reconnecting does not reset it. */
export class ReplayLoopGuard {
  private readonly states = new Map<string, ReplayState>()

  constructor(
    private readonly now: () => number = Date.now,
    private readonly capacity = 4096,
    private readonly idleMs = 600_000,
  ) {}

  allow(identity: string, startSeq: number): boolean {
    const now = this.now()
    let state = this.states.get(identity)
    if (!state || now - state.touchedAt >= this.idleMs) {
      state = {
        lastStart: startSeq, highWater: startSeq, rewinds: 0, repeats: 0, lastServedRecords: false,
        blockedUntil: 0, touchedAt: now,
      }
    }
    this.states.delete(identity)
    this.states.set(identity, state)
    if (this.states.size > this.capacity) this.states.delete(this.states.keys().next().value!)
    state.touchedAt = now

    // A recovered client may continue beyond the old failed pass immediately.
    if (startSeq > state.highWater) {
      state.highWater = startSeq
      state.rewinds = 0
      state.repeats = 0
      state.blockedUntil = 0
    }
    if (now < state.blockedUntil) return false

    // A single retry is normal. Repeated rewinds of at least ten full pages
    // indicate expensive repeated work, unlike empty polling or a page retry.
    if (state.lastStart - startSeq >= 1000) {
      state.rewinds += 1
      state.lastStart = startSeq
      state.repeats = 0
      state.lastServedRecords = false
      if (state.rewinds >= 2) {
        state.blockedUntil = now + Math.min(300_000, 60_000 * 2 ** Math.min(state.rewinds - 2, 3))
        return false
      }
      return true
    }

    // A client that cannot apply a page keeps its cursor and asks for the
    // same non-empty page again. Empty polls at the frontier never count:
    // they carry no records, so lastServedRecords is false for them.
    if (startSeq === state.lastStart && state.lastServedRecords) {
      state.repeats += 1
      if (state.repeats > REPEAT_ALLOWANCE) {
        const step = Math.min(state.repeats - REPEAT_ALLOWANCE - 1, 5)
        state.blockedUntil = now + Math.min(REPEAT_BACKOFF_MAX_MS, REPEAT_BACKOFF_MS * 2 ** step)
        state.lastServedRecords = false
        return false
      }
    } else if (startSeq !== state.lastStart) {
      state.repeats = 0
      state.lastServedRecords = false
    }
    state.lastStart = startSeq
    return true
  }

  /** Records what the last allowed request for `startSeq` returned. */
  served(identity: string, startSeq: number, databaseRecords: number): void {
    const state = this.states.get(identity)
    if (!state || state.lastStart !== startSeq) return
    state.lastServedRecords = databaseRecords > 0
  }
}

export const replayLoopGuard = new ReplayLoopGuard()
