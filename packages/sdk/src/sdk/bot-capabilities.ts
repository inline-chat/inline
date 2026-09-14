export async function registerBotCapabilitiesWithRetry(params: {
  register: () => Promise<unknown>
  retryDelaysMs?: number[]
  isCancelled?: () => boolean
  onFailure?: (error: unknown, willRetry: boolean) => void
  wait?: (delayMs: number) => Promise<void>
}): Promise<boolean> {
  const retryDelaysMs = params.retryDelaysMs ?? [500, 2_000, 5_000]
  const wait = params.wait ?? ((delayMs) => new Promise((resolve) => setTimeout(resolve, delayMs)))
  for (let attempt = 0; ; attempt += 1) {
    if (params.isCancelled?.()) return false
    try {
      await params.register()
      return true
    } catch (error) {
      const willRetry = attempt < retryDelaysMs.length
      params.onFailure?.(error, willRetry)
      if (!willRetry) return false
      await wait(retryDelaysMs[attempt]!)
    }
  }
}
