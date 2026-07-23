import type { InlineCoreSnapshot } from "../core/InlineCoreProtocol"
import type { InlineRuntimeCore } from "./InlineRuntimeCore"

export const waitUntilInlineCoreCacheReady = (
  core: InlineRuntimeCore,
  timeoutMs: number,
) => {
  const current = core.getSnapshot()
  if (current.cacheReady) return Promise.resolve()
  if (current.blockingFailure) {
    return Promise.reject(
      new Error(current.blockingFailure.message),
    )
  }

  return new Promise<void>((resolve, reject) => {
    let settled = false
    let unsubscribe: () => void = () => undefined
    let timeout: ReturnType<typeof setTimeout> | undefined
    const finish = (error?: Error) => {
      if (settled) return
      settled = true
      if (timeout) clearTimeout(timeout)
      unsubscribe()
      if (error) reject(error)
      else resolve()
    }
    const inspect = (snapshot: InlineCoreSnapshot) => {
      if (snapshot.cacheReady) finish()
      else if (snapshot.blockingFailure) {
        finish(new Error(snapshot.blockingFailure.message))
      }
    }
    unsubscribe = core.subscribe(() => inspect(core.getSnapshot()))
    timeout = setTimeout(
      () => finish(new Error("Inline cache did not become ready in time")),
      timeoutMs,
    )
    inspect(core.getSnapshot())
  })
}
