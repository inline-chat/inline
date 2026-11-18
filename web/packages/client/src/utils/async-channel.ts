type ChannelResolver<T> = (result: IteratorResult<T>) => void

export class AsyncChannel<T> implements AsyncIterable<T> {
  private queue: T[] = []
  private resolvers: ChannelResolver<T>[] = []
  private closed = false

  async send(value: T) {
    if (this.closed) return
    const resolver = this.resolvers.shift()
    if (resolver) {
      resolver({ value, done: false })
      return
    }
    this.queue.push(value)
  }

  close() {
    if (this.closed) return
    this.closed = true
    for (const resolver of this.resolvers) {
      resolver({ value: undefined as T, done: true })
    }
    this.resolvers = []
    this.queue = []
  }

  [Symbol.asyncIterator](): AsyncIterator<T> {
    return {
      next: () => {
        if (this.queue.length > 0) {
          const value = this.queue.shift() as T
          return Promise.resolve({ value, done: false })
        }

        if (this.closed) {
          return Promise.resolve({ value: undefined as T, done: true })
        }

        return new Promise<IteratorResult<T>>((resolve) => {
          this.resolvers.push(resolve)
        })
      },
    }
  }
}
