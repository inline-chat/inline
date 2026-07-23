export type InlineSqliteCrashCheckpoint =
  | "before-commit"
  | "after-commit"

export type InlineSqliteCrashHarnessRequest = {
  action: "seed" | "transition" | "verify"
  accountId: string
  checkpoint?: InlineSqliteCrashCheckpoint
}

export type InlineSqliteCrashSnapshot = {
  temporaryStatus?: string
  finalStatus?: string
  outboxStatus?: string
  lastSyncDate?: number
  bucketSeq?: number
  bucketDate?: number
}

export type InlineSqliteCrashHarnessResponse =
  | {
      type: "checkpoint"
      checkpoint: InlineSqliteCrashCheckpoint
      operationCount: number
    }
  | {
      type: "result"
      action: "seed" | "verify"
      snapshot: InlineSqliteCrashSnapshot
    }
  | {
      type: "error"
      name: string
      message: string
      stack?: string
    }
