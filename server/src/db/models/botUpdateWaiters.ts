type Waiter = () => void

export const createBotUpdateWaiters = () => {
  const waiters = new Map<number, Set<Waiter>>()

  const wake = (botUserId: number) => {
    for (const finish of waiters.get(botUserId) ?? []) finish()
  }

  const wakeAll = () => {
    for (const botUserId of waiters.keys()) wake(botUserId)
  }

  const subscribe = (botUserId: number, signal?: AbortSignal) => {
    let finishPromise!: () => void
    const promise = new Promise<void>((resolve) => { finishPromise = resolve })
    const group = waiters.get(botUserId) ?? new Set<Waiter>()
    waiters.set(botUserId, group)
    let timer: ReturnType<typeof setTimeout> | undefined
    let finished = false

    const close = () => {
      if (finished) return
      finished = true
      if (timer !== undefined) clearTimeout(timer)
      group.delete(close)
      if (group.size === 0) waiters.delete(botUserId)
      signal?.removeEventListener("abort", close)
      finishPromise()
    }

    group.add(close)
    signal?.addEventListener("abort", close, { once: true })
    if (signal?.aborted) close()

    return {
      wait: (timeoutMs: number) => {
        if (!finished) timer = setTimeout(close, timeoutMs)
        return promise
      },
      close,
    }
  }

  return { subscribe, wake, wakeAll }
}

export const botUpdateWaiters = createBotUpdateWaiters()
