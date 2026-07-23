import type { UserID } from "@inline/ids"
import {
  acquireInlineRuntimeCore,
  type InlineRuntimeCore,
} from "./InlineRuntimeCore"
import { waitUntilInlineCoreCacheReady } from "./InlineCoreReadiness"

const PREPARED_RUNTIME_TTL_MS = 5_000
const CACHE_READY_TIMEOUT_MS = 10_000

type CoreLease = {
  core: InlineRuntimeCore
  release: () => void
}

type PreparedRuntime = {
  accountId: UserID
  preparedAt: number
  promotedAvatarCount: number
}

type PreparedEntry = {
  promise: Promise<PreparedRuntime>
  release: () => void
  expiresAt: number
  releaseTimer: ReturnType<typeof setTimeout> | null
}

export type InlineRuntimePreloaderDependencies = {
  acquireCore: (accountId: UserID) => CoreLease
  now?: () => number
  payloadTtlMs?: number
  cacheReadyTimeoutMs?: number
}

const abortError = () =>
  new DOMException("Inline runtime preload was cancelled", "AbortError")

const withCallerCancellation = <T>(
  promise: Promise<T>,
  signal?: AbortSignal,
) => {
  if (!signal) return promise
  if (signal.aborted) return Promise.reject(abortError())
  return new Promise<T>((resolve, reject) => {
    const onAbort = () => reject(abortError())
    signal.addEventListener("abort", onAbort, { once: true })
    void promise.then(resolve, reject).finally(() => {
      signal.removeEventListener("abort", onAbort)
    })
  })
}

export class InlineRuntimePreloader {
  private readonly entries = new Map<UserID, PreparedEntry>()
  private readonly now: () => number
  private readonly payloadTtlMs: number
  private readonly cacheReadyTimeoutMs: number

  constructor(
    private readonly dependencies: InlineRuntimePreloaderDependencies,
  ) {
    this.now = dependencies.now ?? Date.now
    this.payloadTtlMs =
      dependencies.payloadTtlMs ?? PREPARED_RUNTIME_TTL_MS
    this.cacheReadyTimeoutMs =
      dependencies.cacheReadyTimeoutMs ?? CACHE_READY_TIMEOUT_MS
  }

  prepare(accountId: UserID, signal?: AbortSignal) {
    const existing = this.entries.get(accountId)
    if (existing && existing.expiresAt > this.now()) {
      return withCallerCancellation(existing.promise, signal)
    }
    if (existing) this.releaseEntry(accountId, existing)

    const lease = this.dependencies.acquireCore(accountId)
    const promise = this.prepareCore(lease.core, accountId)
    const entry: PreparedEntry = {
      promise,
      release: lease.release,
      expiresAt: Number.POSITIVE_INFINITY,
      releaseTimer: null,
    }
    this.entries.set(accountId, entry)
    void promise.then(
      () => this.markPrepared(accountId, entry),
      () => this.releaseEntry(accountId, entry),
    )
    return withCallerCancellation(promise, signal)
  }

  clear() {
    for (const [accountId, entry] of this.entries) {
      this.releaseEntry(accountId, entry)
    }
  }

  private async prepareCore(
    core: InlineRuntimeCore,
    accountId: UserID,
  ): Promise<PreparedRuntime> {
    await core.start()
    await waitUntilInlineCoreCacheReady(
      core,
      this.cacheReadyTimeoutMs,
    )
    return {
      accountId,
      preparedAt: this.now(),
      promotedAvatarCount: 0,
    }
  }

  private markPrepared(accountId: UserID, entry: PreparedEntry) {
    if (this.entries.get(accountId) !== entry) return
    entry.expiresAt = this.now() + this.payloadTtlMs
    entry.releaseTimer = setTimeout(
      () => this.releaseEntry(accountId, entry),
      this.payloadTtlMs,
    )
  }

  private releaseEntry(accountId: UserID, entry: PreparedEntry) {
    if (this.entries.get(accountId) !== entry) return
    this.entries.delete(accountId)
    if (entry.releaseTimer) clearTimeout(entry.releaseTimer)
    entry.release()
  }
}

export const inlineRuntimePreloader = new InlineRuntimePreloader({
  acquireCore: acquireInlineRuntimeCore,
})
