/**
 * What could be lost if this tab reloaded now, and what to save when the
 * page hides. The service worker asks `has()` before it reloads a hidden tab
 * onto a new build (`src/sw/register.ts`); the composer panes register their
 * non-empty state and their draft flush here, and every send is tracked
 * until its first result.
 */

export class UnsavedWork {
  readonly #sources = new Set<() => boolean>()
  readonly #flushers = new Set<() => void>()
  #inFlight = 0

  /** A source of unsaved state (a composer with text). Returns the unregister function. */
  register(source: () => boolean): () => void {
    this.#sources.add(source)
    return () => this.#sources.delete(source)
  }

  /** Something to save on `pagehide` (a composer's pending draft). */
  onFlush(flush: () => void): () => void {
    this.#flushers.add(flush)
    return () => this.#flushers.delete(flush)
  }

  /** Count a send until it settles either way. */
  track<T>(work: Promise<T>): Promise<T> {
    this.#inFlight += 1
    const done = () => {
      this.#inFlight -= 1
    }
    work.then(done, done)
    return work
  }

  get inFlight(): number {
    return this.#inFlight
  }

  has(): boolean {
    if (this.#inFlight > 0) return true
    for (const source of this.#sources) {
      try {
        if (source()) return true
      } catch {
        return true
      }
    }
    return false
  }

  flush(): void {
    for (const flush of this.#flushers) {
      try {
        flush()
      } catch {
        // One failing flush must not stop the others.
      }
    }
  }
}
