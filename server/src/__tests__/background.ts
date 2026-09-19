// Wrap real async work in a spy's implementation to observe its lifetime without
// replacing domain behavior. drain() also catches failures the caller logs.
export function trackBackgroundWork() {
  const pending = new Set<Promise<unknown>>()
  const failures: unknown[] = []
  return {
    wrap<Args extends unknown[], Result extends Promise<unknown> | undefined>(run: (...args: Args) => Result) {
      return (...args: Args): Result => {
        const work = run(...args)
        if (work) {
          pending.add(work)
          void work.then(
            () => pending.delete(work),
            (error) => { pending.delete(work); failures.push(error) },
          )
        }
        return work
      }
    },
    async drain() {
      // A completing job can schedule another job. Drain the entire chain.
      await Promise.resolve()
      while (pending.size) await Promise.allSettled(pending)
      if (failures.length) throw new AggregateError(failures.splice(0), "Background test work failed")
    },
  }
}
