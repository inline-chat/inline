import { ChromeDevtoolsPage } from "./ChromeDevtoolsPage"

const debuggerOrigin = process.argv[2] ?? "http://127.0.0.1:9223"
const appOrigin = process.argv[3] ?? "http://127.0.0.1:8001"
const page = await ChromeDevtoolsPage.open(debuggerOrigin)

try {
  await page.navigate(`${appOrigin}/@vite/client`)
  const proof = await page.evaluate(`(async () => {
    const errors = []
    window.addEventListener("error", (event) => {
      errors.push(event.error?.stack ?? event.message)
    })
    window.addEventListener("unhandledrejection", (event) => {
      errors.push(event.reason?.stack ?? String(event.reason))
    })
    await import(
      "${appOrigin}/src/testing/persistence/InlineSqliteCrashBrowserHarnessPage.ts"
    )
    if (!window.inlineSqliteCrashHarnessReady) {
      throw new Error("SQLite crash harness did not initialize")
    }
    const result = await window.inlineSqliteCrashHarnessReady
    if (errors.length > 0) {
      throw new Error("SQLite crash browser errors: " + JSON.stringify(errors))
    }
    return result
  })()`)
  const typed = proof as {
    beforeCommit: Record<string, unknown>
    afterCommit: Record<string, unknown>
    checkpoints: Array<{
      checkpoint: string
      operationCount: number
    }>
  }
  const require = (condition: unknown, message: string) => {
    if (!condition) throw new Error(message)
  }
  require(
    typed.checkpoints.length === 2 &&
      typed.checkpoints[0]?.checkpoint === "before-commit" &&
      typed.checkpoints[1]?.checkpoint === "after-commit" &&
      typed.checkpoints.every(({ operationCount }) => operationCount === 5),
    `SQLite crash checkpoints were invalid: ${JSON.stringify(typed)}`,
  )
  require(
    typed.beforeCommit.temporaryStatus === "sending" &&
      typed.beforeCommit.finalStatus === undefined &&
      typed.beforeCommit.outboxStatus === "pending" &&
      typed.beforeCommit.lastSyncDate === 100 &&
      typed.beforeCommit.bucketSeq === 1 &&
      typed.beforeCommit.bucketDate === 100,
    `SQLite exposed a partial pre-commit transition: ${JSON.stringify(typed.beforeCommit)}`,
  )
  require(
    typed.afterCommit.temporaryStatus === undefined &&
      typed.afterCommit.finalStatus === "sent" &&
      typed.afterCommit.outboxStatus === undefined &&
      typed.afterCommit.lastSyncDate === 200 &&
      typed.afterCommit.bucketSeq === 2 &&
      typed.afterCommit.bucketDate === 200,
    `SQLite lost or partially applied its durable commit: ${JSON.stringify(typed.afterCommit)}`,
  )
  console.log(JSON.stringify(typed, null, 2))
} finally {
  await page.close()
}
