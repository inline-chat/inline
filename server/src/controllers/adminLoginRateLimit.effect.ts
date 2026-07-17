export interface AdminLoginIpRateLimiter {
  /**
   * Records one attempt when capacity remains. Returns false without recording
   * when the IP already reached the configured window limit.
   */
  readonly tryRecord: (ip: string) => boolean
  readonly clear: (ip: string) => void
  readonly size: () => number
}

export interface AdminLoginIpRateLimiterOptions {
  readonly maxAttempts: number
  readonly windowMs: number
  readonly maxKeys: number
  readonly now?: (() => number) | undefined
}

interface AttemptWindow {
  readonly attempts: number[]
  readonly lastSeenAt: number
}

/**
 * Bounded, process-local protection matching the legacy Admin login policy.
 *
 * The insertion-ordered Map doubles as an LRU queue. Expired windows are
 * removed before capacity eviction, so both keys and timestamps have explicit
 * upper bounds without cloning the entire map on every request.
 *
 * TODO(effect-cutover): move this policy to shared storage before multiple
 * production server instances need one coordinated Admin login window.
 */
export const makeAdminLoginIpRateLimiter = (
  options: AdminLoginIpRateLimiterOptions,
): AdminLoginIpRateLimiter => {
  const now = options.now ?? Date.now
  const windows = new Map<string, AttemptWindow>()

  const deleteExpired = (timestamp: number) => {
    const cutoff = timestamp - options.windowMs
    for (const [ip, window] of windows) {
      if (window.lastSeenAt >= cutoff) {
        break
      }
      windows.delete(ip)
    }
  }

  const touch = (
    ip: string,
    window: AttemptWindow,
  ) => {
    windows.delete(ip)
    windows.set(ip, window)
  }

  return {
    tryRecord: (ip) => {
      const timestamp = now()
      deleteExpired(timestamp)

      const existing = windows.get(ip)
      const cutoff = timestamp - options.windowMs
      const attempts = (
        existing?.attempts ?? []
      ).filter((attempt) => attempt >= cutoff)
      if (attempts.length >= options.maxAttempts) {
        if (existing !== undefined) {
          touch(ip, {
            attempts,
            lastSeenAt: timestamp,
          })
        }
        return false
      }

      if (
        existing === undefined &&
        windows.size >= options.maxKeys
      ) {
        const oldest = windows.keys().next().value
        if (oldest !== undefined) {
          windows.delete(oldest)
        }
      }

      attempts.push(timestamp)
      touch(ip, {
        attempts,
        lastSeenAt: timestamp,
      })
      return true
    },
    clear: (ip) => {
      windows.delete(ip)
    },
    size: () => windows.size,
  }
}
