/**
 * Installs one OPFS SAH pool per account and never lets a failed installation
 * delete or permanently block the replica.
 *
 * Why this exists: a pool installation fails whenever another context still
 * holds the pool's access handles, which is the ordinary tab-takeover case.
 * SQLite's default reaction to a failed installation is to remove the pool's
 * directory. We always install with `preserveOnInitFailure`, give each account
 * its own directory so one account's failure cannot reach another's files, and
 * do not cache a failure, so the next attempt can succeed once the handles
 * are released.
 */

import { InlineSqliteUnavailableError } from "./errors"

export type SahPoolInstallOptions = {
  name: string
  directory: string
  initialCapacity: number
  /** Always true: a failed installation must leave the files in place. */
  preserveOnInitFailure: true
  /** Always true: SQLite caches a failed installation by name otherwise. */
  forceReinitIfPreviouslyFailed: true
}

export type SahPoolInstaller<Pool> = (options: SahPoolInstallOptions) => Promise<Pool>

export type SahPoolLocation = {
  accountId: string
  /**
   * Separates replicas of the same account ID that belong to different
   * servers under one page origin. Defaults to "default".
   */
  namespace?: string
}

export type SahPoolRegistryOptions<Pool> = {
  install: SahPoolInstaller<Pool>
  sleep?: (ms: number) => Promise<void>
  /**
   * Delays before each retry when the pool is held by another context. The
   * previous owner's handles are released shortly after its worker stops.
   */
  busyRetryDelaysMs?: readonly number[]
  initialCapacity?: number
}

export const DEFAULT_BUSY_RETRY_DELAYS_MS: readonly number[] = [50, 100, 200, 400, 800]

const SAFE_SEGMENT = /[^a-z0-9._-]/g

const safeSegment = (value: string, fallback: string) => {
  const cleaned = value
    .toLowerCase()
    .replace(SAFE_SEGMENT, "_")
    .replace(/\.{2,}/g, "_")
    .slice(0, 64)
  return cleaned.length > 0 && cleaned !== "." ? cleaned : fallback
}

export const sahPoolNames = (location: SahPoolLocation) => {
  const namespace = safeSegment(location.namespace ?? "default", "default")
  const account = safeSegment(location.accountId, "unknown")
  return {
    name: `inline-sahpool-v2-${namespace}-${account}`,
    directory: `.inline-sqlite-v2/${namespace}/user-${account}`,
  }
}

const errorName = (error: unknown): string | undefined =>
  typeof error === "object" && error !== null && "name" in error
    ? String((error as { name: unknown }).name)
    : undefined

/** Another context holds an access handle on one of the pool's files. */
export const isSahPoolBusyError = (error: unknown): boolean => {
  if (errorName(error) === "NoModificationAllowedError") return true
  const cause =
    typeof error === "object" && error !== null && "cause" in error
      ? (error as { cause: unknown }).cause
      : undefined
  return cause !== undefined && errorName(cause) === "NoModificationAllowedError"
}

const isStoragePermissionDenied = (error: unknown) => {
  const name = errorName(error)
  return name === "SecurityError" || name === "NotAllowedError"
}

const defaultSleep = (ms: number) =>
  new Promise<void>((resolve) => {
    setTimeout(resolve, ms)
  })

export class SahPoolRegistry<Pool> {
  private readonly pools = new Map<string, Promise<Pool>>()
  private readonly install: SahPoolInstaller<Pool>
  private readonly sleep: (ms: number) => Promise<void>
  private readonly busyRetryDelaysMs: readonly number[]
  private readonly initialCapacity: number

  constructor(options: SahPoolRegistryOptions<Pool>) {
    this.install = options.install
    this.sleep = options.sleep ?? defaultSleep
    this.busyRetryDelaysMs = options.busyRetryDelaysMs ?? DEFAULT_BUSY_RETRY_DELAYS_MS
    this.initialCapacity = options.initialCapacity ?? 6
  }

  /**
   * The pool for an account, installing it on first use. Concurrent callers
   * share one installation. A failure is not remembered: the next call tries
   * again.
   */
  acquire(location: SahPoolLocation): Promise<Pool> {
    const names = sahPoolNames(location)
    const existing = this.pools.get(names.name)
    if (existing) return existing

    const attempt = this.installWithRetry(names)
    this.pools.set(names.name, attempt)
    attempt.catch(() => {
      if (this.pools.get(names.name) === attempt) this.pools.delete(names.name)
    })
    return attempt
  }

  /** Drop the cached pool, after it has been removed or its worker is going away. */
  forget(location: SahPoolLocation) {
    this.pools.delete(sahPoolNames(location).name)
  }

  private async installWithRetry(names: { name: string; directory: string }): Promise<Pool> {
    let attempt = 0
    for (;;) {
      try {
        return await this.install({
          name: names.name,
          directory: names.directory,
          initialCapacity: this.initialCapacity,
          preserveOnInitFailure: true,
          forceReinitIfPreviouslyFailed: true,
        })
      } catch (cause) {
        if (cause instanceof InlineSqliteUnavailableError) throw cause
        if (isStoragePermissionDenied(cause)) {
          throw new InlineSqliteUnavailableError("opfs-permission-denied", { cause })
        }
        if (!isSahPoolBusyError(cause)) {
          throw new InlineSqliteUnavailableError("opfs-initialization-failed", { cause })
        }
        const delay = this.busyRetryDelaysMs[attempt]
        if (delay === undefined) {
          throw new InlineSqliteUnavailableError("opfs-busy", { cause })
        }
        attempt += 1
        await this.sleep(delay)
      }
    }
  }
}
