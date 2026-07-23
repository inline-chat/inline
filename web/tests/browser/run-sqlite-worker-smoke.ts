import { ChromeDevtoolsPage } from "./ChromeDevtoolsPage"

const debuggerOrigin = process.argv[2] ?? "http://127.0.0.1:9223"
const appOrigin = process.argv[3] ?? "http://127.0.0.1:8001"
const harnessDocument = await Bun.file(
  new URL("../fixtures/sqlite-worker-harness.html", import.meta.url),
).text()
const page = await ChromeDevtoolsPage.open(debuggerOrigin)

try {
  // Use a stable same-origin Vite resource rather than the product root,
  // whose authenticated router may replace the execution context while this
  // harness is attaching.
  await page.navigate(`${appOrigin}/@vite/client`)
  const harnessUrl = await page.evaluate<string>(`URL.createObjectURL(
    new Blob([${JSON.stringify(harnessDocument)}], { type: "text/html" })
  )`)
  await page.navigate(harnessUrl)
  const result = await page.evaluate(`(async () => {
    const errors = []
    window.addEventListener("error", (event) => {
      errors.push(event.error?.stack ?? event.message)
    })
    window.addEventListener("unhandledrejection", (event) => {
      errors.push(event.reason?.stack ?? String(event.reason))
    })
    await import(
      "${appOrigin}/src/testing/persistence/InlineSqliteWorkerBrowserHarnessPage.ts"
    )
    if (!window.inlineSqliteWorkerHarnessReady) {
      throw new Error(
        "SQLite worker harness did not initialize: " + JSON.stringify(errors)
      )
    }
    const proof = await window.inlineSqliteWorkerHarnessReady
    if (errors.length > 0) {
      throw new Error("SQLite worker browser errors: " + JSON.stringify(errors))
    }
    return proof
  })()`)
  const typed = result as {
    seed: Record<string, unknown>
    verify: Record<string, unknown>
    selection: Record<string, unknown>
    mainThreadLongTasks: Array<{
      phase: string
      startTime: number
      duration: number
    }>
    mainThreadFrameGaps: Array<{
      phase: string
      timestamp: number
      duration: number
    }>
    mainThreadMaxFrameGapByPhase: Record<string, number>
    mainThreadMaxFrameGapMs: number
    mainThreadFrameCount: number
  }
  const require = (condition: unknown, message: string) => {
    if (!condition) throw new Error(message)
  }
  for (const phase of [typed.seed, typed.verify]) {
    require(
      phase.latestCount === 60,
      `latest window failed: ${JSON.stringify(phase)}`,
    )
    require(
      phase.latestFirstId === "9941" &&
        phase.latestLastId === "10000",
      `latest IDs failed: ${JSON.stringify(phase)}`,
    )
    require(
      phase.aroundCount === 60 &&
        phase.aroundFirstId === "4970" &&
        phase.aroundLastId === "5029",
      `around window failed: ${JSON.stringify(phase)}`,
    )
    require(
      phase.exactUserId === "900000000000000002",
      `exact user failed: ${JSON.stringify(phase)}`,
    )
    require(
      phase.transactionId === "sqlite-browser-outbox" &&
        phase.lastSyncDate === 1_700_000_123,
      `restart state failed: ${JSON.stringify(phase)}`,
    )
  }
  require(
    typed.mainThreadLongTasks.length === 0,
    `SQLite worker blocked the main thread: ${JSON.stringify(typed)}`,
  )
  require(
    typed.selection.primaryPhase === "primary" &&
      typed.selection.fallbackPhase === "fallback" &&
      typed.selection.restartPhase === "fallback",
    `SQLite startup selection failed: ${JSON.stringify(typed.selection)}`,
  )
  require(
    typed.selection.importedUserName === "Legacy" &&
      typed.selection.importedDraftText ===
        "Imported before realtime" &&
      typed.selection.importedOutboxId === "legacy-cutover-outbox" &&
      typed.selection.importedOutboxRandomId ===
        "9223372036854775806" &&
      typed.selection.markedUserName === "Legacy",
    `legacy IndexedDB cutover failed: ${JSON.stringify(typed.selection)}`,
  )
  require(
    typed.selection.promotedFallbackRefused === true &&
      typed.selection.promotedFallbackPhase === "failed" &&
      typed.selection.currentRuntimeRefused === true,
    `promoted SQLite replica exposed stale IndexedDB: ${JSON.stringify(typed.selection)}`,
  )
  require(
    typed.selection.fallbackUserId === "900000000000000002" &&
      typed.selection.fallbackOutboxId === "sqlite-selection-outbox" &&
      typed.selection.fallbackOutboxRandomId ===
        "9223372036854775807",
    `IndexedDB Worker fallback did not survive restart: ${JSON.stringify(typed.selection)}`,
  )
  require(
    typed.selection.refusedReason === "opfs-initialization-failed" &&
      typed.selection.unsafeFallbackCreated === false,
    `unsafe SQLite failure switched replicas: ${JSON.stringify(typed.selection)}`,
  )
  require(
    typed.mainThreadFrameCount > 0 &&
      typed.mainThreadMaxFrameGapMs <= 50 &&
      (typed.mainThreadMaxFrameGapByPhase.selection ?? Infinity) < 34 &&
      (typed.mainThreadMaxFrameGapByPhase.verify ?? Infinity) < 34,
    `SQLite worker missed an interactive frame budget: ${JSON.stringify(typed)}`,
  )
  console.log(JSON.stringify(typed, null, 2))
} finally {
  await page.close()
}
