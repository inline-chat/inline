import { ChromeDevtoolsPage } from "./ChromeDevtoolsPage"

const debuggerOrigin = process.argv[2] ?? "http://127.0.0.1:9223"
const appOrigin = process.argv[3] ?? "http://127.0.0.1:8001"
const page = await ChromeDevtoolsPage.open(debuggerOrigin)

try {
  await page.navigate(`${appOrigin}/__inline-harness/media-cache`)
  const seed = await page.evaluate(`(async () => {
    const deadline = performance.now() + 10_000
    while (!window.inlineMediaPersistenceHarnessReady) {
      if (performance.now() >= deadline) {
        throw new Error(
          "Persistent media harness did not initialize: " +
          JSON.stringify({
            errors: window.inlineMediaPersistenceHarnessErrors,
            resources: performance.getEntriesByType("resource").map(
              (entry) => entry.name
            )
          })
        )
      }
      await new Promise((resolve) => requestAnimationFrame(resolve))
    }
    return await window.inlineMediaPersistenceHarness.seed()
  })()`)

  // Recreate the whole document/module graph before reading the same account
  // cache. This is stronger than constructing a second adapter in one page.
  await page.reload()
  await page.setNetworkOffline(true)
  const reopened = await page.evaluate(`(async () => {
    const deadline = performance.now() + 10_000
    while (!window.inlineMediaPersistenceHarnessReady) {
      if (performance.now() >= deadline) {
        throw new Error(
          "Persistent media harness did not reinitialize: " +
          JSON.stringify({
            errors: window.inlineMediaPersistenceHarnessErrors,
            resources: performance.getEntriesByType("resource").map(
              (entry) => entry.name
            )
          })
        )
      }
      await new Promise((resolve) => requestAnimationFrame(resolve))
    }
    const result = await window.inlineMediaPersistenceHarness.reopenOffline()
    if (window.inlineMediaPersistenceHarnessErrors.length) {
      throw new Error(
        "Persistent media browser errors: " +
        JSON.stringify(window.inlineMediaPersistenceHarnessErrors)
      )
    }
    if (
      result.resourceKind !== "blob" ||
      result.promoted !== 1 ||
      result.firstCommitSource !== result.blobUrl ||
      result.frameWidth !== "320px" ||
      result.frameHeight !== "240px" ||
      result.rotatedUrlResourceRequests !== 0 ||
      result.online !== false ||
      result.fallback?.kind !== "blob" ||
      result.fallback?.promoted !== 1 ||
      result.fallback?.bytesMatch !== true ||
      result.fallbackOpfsDirectoryExists !== false ||
      result.boundedLru?.opfs?.first !== true ||
      result.boundedLru?.opfs?.second !== false ||
      result.boundedLru?.opfs?.third !== true ||
      result.boundedLru?.indexedDb?.first !== true ||
      result.boundedLru?.indexedDb?.second !== false ||
      result.boundedLru?.indexedDb?.third !== true
    ) {
      throw new Error(
        "Persistent media acceptance failed: " + JSON.stringify(result)
      )
    }
    return result
  })()`)

  console.log(JSON.stringify({ seed, reopened }, null, 2))
} finally {
  await page.setNetworkOffline(false).catch(() => undefined)
  await page.close()
}
