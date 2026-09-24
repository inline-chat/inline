/**
 * Tracks detached application work that can still hold database resources.
 * Request paths register work without awaiting it; shutdown and test teardown
 * drain the registry before closing or truncating the database.
 */
export class BackgroundWork {
  private readonly pending = new Set<Promise<unknown>>()

  track(work: Promise<unknown>): void {
    this.pending.add(work)
    void work.then(
      () => this.pending.delete(work),
      () => this.pending.delete(work),
    )
  }

  async waitForIdle(): Promise<void> {
    while (this.pending.size > 0) {
      await Promise.allSettled(this.pending)
    }
  }
}

/** Detached work owned by application modules rather than a connection. */
export const applicationBackgroundWork = new BackgroundWork()
