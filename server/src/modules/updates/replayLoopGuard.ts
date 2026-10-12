type ReplayState = { lastStart: number; highWater: number; rewinds: number; blockedUntil: number; touchedAt: number }

/** Bounds repeated large catch-up rewinds on one socket without discarding history.
 * New forward progress, a new connection, and idle expiry remain available. */
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
      state = { lastStart: startSeq, highWater: startSeq, rewinds: 0, blockedUntil: 0, touchedAt: now }
    }
    this.states.delete(identity)
    this.states.set(identity, state)
    if (this.states.size > this.capacity) this.states.delete(this.states.keys().next().value!)
    state.touchedAt = now

    // A recovered client may continue beyond the old failed pass immediately.
    if (startSeq > state.highWater) {
      state.highWater = startSeq
      state.blockedUntil = 0
    }
    if (now < state.blockedUntil) return false

    // A single retry is normal. Repeated rewinds of at least ten full pages
    // indicate expensive repeated work, unlike empty polling or a page retry.
    if (state.lastStart - startSeq >= 1000) {
      state.rewinds += 1
      state.lastStart = startSeq
      if (state.rewinds >= 2) {
        state.blockedUntil = now + Math.min(300_000, 60_000 * 2 ** Math.min(state.rewinds - 2, 3))
        return false
      }
    }
    state.lastStart = startSeq
    return true
  }
}

export const replayLoopGuard = new ReplayLoopGuard()
