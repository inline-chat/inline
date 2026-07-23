export class FetchLimiter {
  private active = 0
  private readonly waiters: Array<() => void> = []

  constructor(private readonly limit: number) {
    if (!Number.isInteger(limit) || limit < 1) {
      throw new Error("FetchLimiter requires a positive integer limit")
    }
  }

  async run<T>(operation: () => Promise<T>): Promise<T> {
    await this.acquire()
    try {
      return await operation()
    } finally {
      this.release()
    }
  }

  private async acquire() {
    if (this.active < this.limit) {
      this.active += 1
      return
    }

    await new Promise<void>((resolve) => {
      this.waiters.push(resolve)
    })
    this.active += 1
  }

  private release() {
    this.active -= 1
    this.waiters.shift()?.()
  }
}
