import type { UserID } from "@inline/ids"

export type InlineCoreAccountOwnership = {
  release(): Promise<void>
}

export type InlineCoreAccountOwnershipAcquirer = (
  accountId: UserID,
) => Promise<InlineCoreAccountOwnership | null>

export type InlineCoreLockManager = {
  request<T>(
    name: string,
    options: { mode: "exclusive"; ifAvailable: true },
    callback: (lock: unknown | null) => Promise<T>,
  ): Promise<T>
}

export const inlineCoreAccountLockName = (accountId: UserID) =>
  `inline-core-account-${accountId}`

/**
 * Acquires the unversioned account writer lock without waiting behind another
 * bundle generation. The caller keeps the returned lease until its account
 * core has stopped and its persistence handle has closed.
 */
export const createInlineCoreAccountOwnershipAcquirer = (
  locks: InlineCoreLockManager | undefined,
): InlineCoreAccountOwnershipAcquirer => async (accountId) => {
  if (!locks) return null

  let releaseLock: (() => void) | undefined
  let resolveAcquisition:
    | ((ownership: InlineCoreAccountOwnership | null) => void)
    | undefined
  let rejectAcquisition: ((error: unknown) => void) | undefined
  let acquired = false
  let released = false
  let requestTask: Promise<unknown> | undefined
  const releasedSignal = new Promise<void>((resolve) => {
    releaseLock = resolve
  })
  const acquisition = new Promise<InlineCoreAccountOwnership | null>(
    (resolve, reject) => {
      resolveAcquisition = resolve
      rejectAcquisition = reject
    },
  )

  requestTask = locks.request(
    inlineCoreAccountLockName(accountId),
    { mode: "exclusive", ifAvailable: true },
    async (lock) => {
      if (!lock) {
        resolveAcquisition?.(null)
        return
      }
      acquired = true
      resolveAcquisition?.({
        release: async () => {
          if (!released) {
            released = true
            releaseLock?.()
          }
          await requestTask
        },
      })
      await releasedSignal
    },
  )
  void requestTask.catch((error: unknown) => {
    if (!acquired) rejectAcquisition?.(error)
  })

  return acquisition
}
