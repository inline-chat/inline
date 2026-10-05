import type { UserID } from "@inline/ids"

export type AccountWriter = { release(): Promise<void> }

// Shared with earlier Inline web bundles: a new cache format is not a new writer.
export const accountWriterName = (accountId: UserID) =>
  `inline-core-account-${accountId}`

/** Queue for the account writer; abort only cancels an acquisition still waiting. */
export const acquireAccountWriter = (
  locks: LockManager,
  accountId: UserID,
  signal: AbortSignal,
): Promise<AccountWriter> => {
  let resolveAcquisition!: (writer: AccountWriter) => void
  let rejectAcquisition!: (error: unknown) => void
  const acquisition = new Promise<AccountWriter>((resolve, reject) => {
    resolveAcquisition = resolve
    rejectAcquisition = reject
  })
  let releaseLock!: () => void
  const released = new Promise<void>((resolve) => { releaseLock = resolve })
  let releaseTask: Promise<void> | undefined
  let requestTask: Promise<void>

  try {
    requestTask = locks.request(
      accountWriterName(accountId),
      { mode: "exclusive", signal },
      async () => {
        if (signal.aborted) {
          rejectAcquisition(signal.reason)
          return
        }
        resolveAcquisition({
          release: () => {
            if (!releaseTask) {
              releaseLock()
              releaseTask = requestTask
            }
            return releaseTask
          },
        })
        await released
      },
    )
    void requestTask.catch(rejectAcquisition)
  } catch (error) {
    rejectAcquisition(error)
  }
  return acquisition
}
