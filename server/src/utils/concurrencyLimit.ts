/**
 * Runs at most `max` tasks at once; later callers wait in FIFO order.
 * A finished task hands its slot straight to the next waiter.
 */
export function concurrencyLimit(max: number) {
  let active = 0
  const waiting: Array<() => void> = []

  return async function run<T>(task: () => Promise<T>): Promise<T> {
    if (active < max) {
      active++
    } else {
      await new Promise<void>((resolve) => waiting.push(resolve))
    }
    try {
      return await task()
    } finally {
      const next = waiting.shift()
      if (next) next()
      else active--
    }
  }
}
