import type {
  InlineSqliteCrashCheckpoint,
  InlineSqliteCrashHarnessRequest,
  InlineSqliteCrashHarnessResponse,
  InlineSqliteCrashSnapshot,
} from "./InlineSqliteCrashHarnessProtocol"

type InlineSqliteCrashBrowserProof = {
  beforeCommit: InlineSqliteCrashSnapshot
  afterCommit: InlineSqliteCrashSnapshot
  checkpoints: Array<{
    checkpoint: InlineSqliteCrashCheckpoint
    operationCount: number
  }>
}

declare global {
  interface Window {
    inlineSqliteCrashHarnessReady?: Promise<InlineSqliteCrashBrowserProof>
  }
}

const worker = () =>
  new Worker(
    new URL(
      "./InlineSqliteCrashHarness.worker.ts",
      import.meta.url,
    ),
    { type: "module" },
  )

const runWorker = (
  request: InlineSqliteCrashHarnessRequest,
): Promise<InlineSqliteCrashSnapshot> =>
  new Promise((resolve, reject) => {
    const instance = worker()
    const timeout = window.setTimeout(() => {
      instance.terminate()
      reject(new Error(`SQLite crash ${request.action} timed out`))
    }, 120_000)
    instance.addEventListener("message", (event) => {
      const response = event.data as InlineSqliteCrashHarnessResponse
      if (response.type === "checkpoint") return
      window.clearTimeout(timeout)
      instance.terminate()
      if (response.type === "error") {
        const error = new Error(response.message)
        error.name = response.name
        error.stack = response.stack ?? error.stack
        reject(error)
      } else {
        resolve(response.snapshot)
      }
    })
    instance.addEventListener("error", (event) => {
      window.clearTimeout(timeout)
      instance.terminate()
      reject(event.error ?? new Error(event.message))
    })
    instance.postMessage(request)
  })

const terminateAt = (
  accountId: string,
  checkpoint: InlineSqliteCrashCheckpoint,
) =>
  new Promise<{ checkpoint: InlineSqliteCrashCheckpoint; operationCount: number }>(
    (resolve, reject) => {
      const instance = worker()
      const timeout = window.setTimeout(() => {
        instance.terminate()
        reject(new Error(`SQLite ${checkpoint} checkpoint timed out`))
      }, 120_000)
      instance.addEventListener("message", (event) => {
        const response = event.data as InlineSqliteCrashHarnessResponse
        if (response.type === "error") {
          window.clearTimeout(timeout)
          instance.terminate()
          reject(new Error(`${response.name}: ${response.message}`))
          return
        }
        if (response.type !== "checkpoint") return
        window.clearTimeout(timeout)
        instance.terminate()
        resolve({
          checkpoint: response.checkpoint,
          operationCount: response.operationCount,
        })
      })
      instance.addEventListener("error", (event) => {
        window.clearTimeout(timeout)
        instance.terminate()
        reject(event.error ?? new Error(event.message))
      })
      instance.postMessage({
        action: "transition",
        accountId,
        checkpoint,
      } satisfies InlineSqliteCrashHarnessRequest)
    },
  )

const settleTerminatedWorker = () =>
  new Promise<void>((resolve) => window.setTimeout(resolve, 50))

const run = async (): Promise<InlineSqliteCrashBrowserProof> => {
  const beforeAccountId = "900000000000000051"
  const afterAccountId = "900000000000000052"
  await runWorker({ action: "seed", accountId: beforeAccountId })
  await runWorker({ action: "seed", accountId: afterAccountId })

  const beforeCheckpoint = await terminateAt(
    beforeAccountId,
    "before-commit",
  )
  await settleTerminatedWorker()
  const beforeCommit = await runWorker({
    action: "verify",
    accountId: beforeAccountId,
  })

  const afterCheckpoint = await terminateAt(
    afterAccountId,
    "after-commit",
  )
  await settleTerminatedWorker()
  const afterCommit = await runWorker({
    action: "verify",
    accountId: afterAccountId,
  })

  return {
    beforeCommit,
    afterCommit,
    checkpoints: [beforeCheckpoint, afterCheckpoint],
  }
}

window.inlineSqliteCrashHarnessReady = run()
