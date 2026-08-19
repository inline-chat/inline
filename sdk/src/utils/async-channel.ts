type ChannelResolver<T> = (result: IteratorResult<T>) => void

type ChannelWaiter<T> = {
  resolve: ChannelResolver<T>
  reject: (error: Error) => void
}

type QueuedChannelItem<T> = {
  value: T
  bytes: number
}

type AsyncChannelByteLimit<T> = {
  capacityBytes: number
  byteLength: (value: T) => number
}

type AcknowledgedChannelWaiter<T> = {
  resolve: ChannelResolver<T>
  reject: (error: Error) => void
}

type AcknowledgedChannelItem<T> = {
  value: T
  bytes: number
  acknowledge: (applied: boolean) => void
}

export class AsyncChannelOverflowError extends Error {
  constructor(readonly capacity: number) {
    super(`Async channel capacity ${capacity} exceeded`)
    this.name = "AsyncChannelOverflowError"
  }
}

export class AsyncChannelByteOverflowError extends Error {
  constructor(readonly capacityBytes: number) {
    super(`Async channel byte capacity ${capacityBytes} exceeded`)
    this.name = "AsyncChannelByteOverflowError"
  }
}

export class AsyncChannel<T> implements AsyncIterable<T> {
  private queue: QueuedChannelItem<T>[] = []
  private queuedBytes = 0
  private waiters: ChannelWaiter<T>[] = []
  private closed = false
  private failure: Error | null = null

  constructor(
    private readonly capacity = Number.POSITIVE_INFINITY,
    private readonly byteLimit?: AsyncChannelByteLimit<T>,
  ) {
    if (capacity !== Number.POSITIVE_INFINITY && (!Number.isSafeInteger(capacity) || capacity <= 0)) {
      throw new Error("AsyncChannel capacity must be a positive safe integer")
    }
    if (byteLimit && (!Number.isSafeInteger(byteLimit.capacityBytes) || byteLimit.capacityBytes <= 0)) {
      throw new Error("AsyncChannel byte capacity must be a positive safe integer")
    }
  }

  async send(value: T) {
    if (this.closed) return
    const waiter = this.waiters.shift()
    if (waiter) {
      waiter.resolve({ value, done: false })
      return
    }
    if (this.queue.length >= this.capacity) throw new AsyncChannelOverflowError(this.capacity)
    const bytes = this.byteLimit?.byteLength(value) ?? 0
    if (!Number.isSafeInteger(bytes) || bytes < 0) {
      throw new Error("AsyncChannel item byte length must be a non-negative safe integer")
    }
    if (this.byteLimit && this.queuedBytes + bytes > this.byteLimit.capacityBytes) {
      throw new AsyncChannelByteOverflowError(this.byteLimit.capacityBytes)
    }
    this.queue.push({ value, bytes })
    this.queuedBytes += bytes
  }

  close() {
    if (this.closed) return
    this.closed = true
    for (const waiter of this.waiters) {
      waiter.resolve({ value: undefined as T, done: true })
    }
    this.waiters = []
    this.queue = []
    this.queuedBytes = 0
  }

  fail(error: Error) {
    if (this.closed) return
    this.closed = true
    this.failure = error
    for (const waiter of this.waiters) waiter.reject(error)
    this.waiters = []
    this.queue = []
    this.queuedBytes = 0
  }

  [Symbol.asyncIterator](): AsyncIterator<T> {
    return {
      next: () => {
        if (this.queue.length > 0) {
          const item = this.queue.shift() as QueuedChannelItem<T>
          this.queuedBytes -= item.bytes
          return Promise.resolve({ value: item.value, done: false })
        }

        if (this.closed) {
          if (this.failure) return Promise.reject(this.failure)
          return Promise.resolve({ value: undefined as T, done: true })
        }

        return new Promise<IteratorResult<T>>((resolve, reject) => {
          this.waiters.push({ resolve, reject })
        })
      },
    }
  }
}

/**
 * A single-consumer channel whose producer receives an application acknowledgement.
 *
 * An item is acknowledged when the consumer asks for the next item. With an ordinary
 * `for await` loop that happens only after the loop body for the previous item has
 * completed. Closing or abandoning the iterator resolves the outstanding delivery as
 * unacknowledged so its cursor can be recovered instead of being advanced silently.
 */
export class AcknowledgedAsyncChannel<T> implements AsyncIterable<T> {
  private readonly queue: AcknowledgedChannelItem<T>[] = []
  private waiter: AcknowledgedChannelWaiter<T> | null = null
  private active: AcknowledgedChannelItem<T> | null = null
  private bufferedBytes = 0
  private closed = false
  private failure: Error | null = null
  private iteratorClaimed = false

  constructor(
    private readonly capacity: number,
    private readonly byteLimit?: AsyncChannelByteLimit<T>,
  ) {
    if (!Number.isSafeInteger(capacity) || capacity <= 0) {
      throw new Error("AcknowledgedAsyncChannel capacity must be a positive safe integer")
    }
    if (byteLimit && (!Number.isSafeInteger(byteLimit.capacityBytes) || byteLimit.capacityBytes <= 0)) {
      throw new Error("AcknowledgedAsyncChannel byte capacity must be a positive safe integer")
    }
  }

  send(value: T): Promise<boolean> {
    if (this.closed) return Promise.resolve(false)
    if (!this.waiter && this.queue.length >= this.capacity) {
      throw new AsyncChannelOverflowError(this.capacity)
    }
    const bytes = this.byteLimit?.byteLength(value) ?? 0
    if (!Number.isSafeInteger(bytes) || bytes < 0) {
      throw new Error("AcknowledgedAsyncChannel item byte length must be a non-negative safe integer")
    }
    if (this.byteLimit && this.bufferedBytes + bytes > this.byteLimit.capacityBytes) {
      throw new AsyncChannelByteOverflowError(this.byteLimit.capacityBytes)
    }

    return new Promise<boolean>((acknowledge) => {
      const item = { value, bytes, acknowledge }
      this.bufferedBytes += bytes
      const waiter = this.waiter
      if (waiter) {
        this.waiter = null
        this.active = item
        waiter.resolve({ value, done: false })
      } else {
        this.queue.push(item)
      }
    })
  }

  close() {
    this.finish(null)
  }

  fail(error: Error) {
    this.finish(error)
  }

  private finish(error: Error | null) {
    if (this.closed) return
    this.closed = true
    this.failure = error
    this.active?.acknowledge(false)
    this.active = null
    for (const item of this.queue) item.acknowledge(false)
    this.queue.length = 0
    this.bufferedBytes = 0

    const waiter = this.waiter
    this.waiter = null
    if (!waiter) return
    if (error) waiter.reject(error)
    else waiter.resolve({ value: undefined as T, done: true })
  }

  [Symbol.asyncIterator](): AsyncIterator<T> {
    if (this.iteratorClaimed) {
      return {
        next: () => Promise.reject(new Error("AcknowledgedAsyncChannel supports one consumer")),
      }
    }
    this.iteratorClaimed = true

    return {
      next: () => {
        if (this.active) {
          this.bufferedBytes -= this.active.bytes
          this.active.acknowledge(true)
        }
        this.active = null

        const item = this.queue.shift()
        if (item) {
          this.active = item
          return Promise.resolve({ value: item.value, done: false })
        }

        if (this.closed) {
          if (this.failure) return Promise.reject(this.failure)
          return Promise.resolve({ value: undefined as T, done: true })
        }

        if (this.waiter) {
          return Promise.reject(new Error("AcknowledgedAsyncChannel does not allow concurrent next() calls"))
        }
        return new Promise<IteratorResult<T>>((resolve, reject) => {
          this.waiter = { resolve, reject }
        })
      },
      return: () => {
        if (this.active) {
          this.bufferedBytes -= this.active.bytes
          this.active.acknowledge(false)
        }
        this.active = null
        this.iteratorClaimed = false
        return Promise.resolve({ value: undefined as T, done: true })
      },
    }
  }
}
