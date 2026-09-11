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

export class ChannelConsumerError extends Error {
  constructor(message: string) {
    super(message)
    this.name = "ChannelConsumerError"
  }
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
    private readonly byteLimit?: AsyncChannelByteLimit<T>
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
  private consumption: {
    handler: (value: T) => Promise<void>
    key: (value: T) => string | null
    concurrency: number
    active: Map<AcknowledgedChannelItem<T>, string | null>
    resolve: () => void
    reject: (error: Error) => void
  } | null = null

  constructor(private readonly capacity: number, private readonly byteLimit?: AsyncChannelByteLimit<T>) {
    if (!Number.isSafeInteger(capacity) || capacity <= 0) {
      throw new Error("AcknowledgedAsyncChannel capacity must be a positive safe integer")
    }
    if (byteLimit && (!Number.isSafeInteger(byteLimit.capacityBytes) || byteLimit.capacityBytes <= 0)) {
      throw new Error("AcknowledgedAsyncChannel byte capacity must be a positive safe integer")
    }
  }

  send(value: T): Promise<boolean> {
    if (this.closed) return Promise.resolve(false)
    if (!this.waiter && this.queue.length + (this.consumption?.active.size ?? 0) >= this.capacity) {
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
        this.pumpConsumption()
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
    const consumption = this.consumption
    this.consumption = null
    if (consumption) {
      for (const item of consumption.active.keys()) item.acknowledge(false)
      if (error) consumption.reject(error)
      else consumption.resolve()
    }
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

  /** Process independent keys concurrently without acknowledging queued work.
   * A null key is a global barrier. Rejection fails the stream, retaining cursors.
   */
  consume(handler: (value: T) => Promise<void>, key: (value: T) => string | null, concurrency = 8): Promise<void> {
    if (this.iteratorClaimed)
      return Promise.reject(new ChannelConsumerError("AcknowledgedAsyncChannel supports one consumer"))
    if (!Number.isSafeInteger(concurrency) || concurrency < 1) {
      return Promise.reject(new ChannelConsumerError("Consumer concurrency must be a positive safe integer"))
    }
    if (this.closed) return this.failure ? Promise.reject(this.failure) : Promise.resolve()
    this.iteratorClaimed = true
    return new Promise<void>((resolve, reject) => {
      this.consumption = { handler, key, concurrency, active: new Map(), resolve, reject }
      this.pumpConsumption()
    })
  }

  private pumpConsumption() {
    const owner = this.consumption
    if (!owner || this.closed) return
    try {
      while (owner.active.size < owner.concurrency && this.queue.length > 0) {
        if ([...owner.active.values()].includes(null)) return
        const keys = new Set(owner.active.values())
        let index = -1
        let key: string | null = null
        for (let i = 0; i < this.queue.length; i++) {
          const candidate = this.queue[i]!
          const candidateKey = owner.key(candidate.value)
          if (candidateKey === null) {
            if (i === 0 && owner.active.size === 0) index = i
            break
          }
          if (!keys.has(candidateKey)) {
            index = i
            key = candidateKey
            break
          }
        }
        if (index < 0) return
        const item = this.queue.splice(index, 1)[0]!
        owner.active.set(item, key)
        void Promise.resolve()
          .then(() => owner.handler(item.value))
          .then(
            () => {
              if (this.consumption !== owner) return
              owner.active.delete(item)
              this.bufferedBytes -= item.bytes
              item.acknowledge(true)
              this.pumpConsumption()
            },
            (error: unknown) => {
              if (this.consumption === owner)
                this.fail(error instanceof Error ? error : new Error("Inbound handler failed"))
            }
          )
      }
    } catch (error) {
      this.fail(error instanceof Error ? error : new Error("Inbound routing failed"))
    }
  }

  [Symbol.asyncIterator](): AsyncIterator<T> {
    if (this.iteratorClaimed) {
      return {
        next: () => Promise.reject(new Error("AcknowledgedAsyncChannel supports one consumer")),
      }
    }
    this.iteratorClaimed = true
    let returned = false

    return {
      next: () => {
        if (returned) return Promise.resolve({ value: undefined as T, done: true })
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
        if (returned) return Promise.resolve({ value: undefined as T, done: true })
        returned = true
        this.waiter?.resolve({ value: undefined as T, done: true })
        this.waiter = null
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
