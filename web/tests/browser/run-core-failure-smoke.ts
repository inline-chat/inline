import { ChromeDevtoolsBrowser } from "./ChromeDevtoolsBrowser"
import { ChromeDevtoolsPage } from "./ChromeDevtoolsPage"

const debuggerOrigin =
  process.argv[2] ?? "http://127.0.0.1:9223"
const appOrigin = process.argv[3] ?? "http://127.0.0.1:8001"
const harnessDocument = (
  await Bun.file(
    new URL("../fixtures/core-failure-harness.html", import.meta.url),
  ).text()
).replaceAll("__INLINE_APP_ORIGIN__", appOrigin)
const page = await ChromeDevtoolsPage.open(debuggerOrigin)
const browser = await ChromeDevtoolsBrowser.open(debuggerOrigin)

try {
  await page.navigate(appOrigin)
  const harnessUrl = await page.evaluate<string>(`URL.createObjectURL(
    new Blob([${JSON.stringify(harnessDocument)}], { type: "text/html" })
  )`)
  await page.navigate(harnessUrl)
  await page.evaluate(`(async () => {
    const deadline = performance.now() + 5_000
    while (!window.inlineCoreFailureHarness) {
      if (performance.now() >= deadline) {
        throw new Error("Inline core failure harness did not initialize")
      }
      await new Promise((resolve) => requestAnimationFrame(resolve))
    }
  })()`)

  const firstOwner = await page.evaluate<string>(
    `window.inlineCoreFailureHarness.connect()`,
  )
  const draftText = "Draft surviving worker termination"
  await page.evaluate(
    `window.inlineCoreFailureHarness.saveDraft(${JSON.stringify(draftText)})`,
  )

  const targets = await browser.targets()
  const workers = targets.filter(
    (target) =>
      target.type === "shared_worker" &&
      target.url.includes("InlineCore.shared-worker"),
  )
  if (workers.length !== 1) {
    throw new Error(
      `Expected one Inline SharedWorker target, found ${workers.length}: ${JSON.stringify(
        targets.map(({ type, title, url }) => ({ type, title, url })),
      )}`,
    )
  }
  await browser.closeTarget(workers[0]!.targetId)

  const failure = await page.evaluate<{
    phase: string
    recoveryAction?: string
    bootstrapError?: string
  }>(`window.inlineCoreFailureHarness.waitForFailure()`)
  if (
    failure.phase !== "error" ||
    failure.recoveryAction !== "reload"
  ) {
    throw new Error(
      `Worker termination did not become explicit recovery state: ${JSON.stringify(failure)}`,
    )
  }
  const terminalStart = await page.evaluate<{
    code?: string
    message: string
  }>(`window.inlineCoreFailureHarness.startAfterFailure()`)
  if (terminalStart.code !== "owner-failed") {
    throw new Error(
      `Failed renderer was reusable: ${JSON.stringify(terminalStart)}`,
    )
  }

  const recoveredOwner = await page.evaluate<string>(
    `window.inlineCoreFailureHarness.recover()`,
  )
  if (recoveredOwner === firstOwner) {
    throw new Error("Explicit recovery reused the terminated owner")
  }
  const restoredDraft = await page.evaluate<string | undefined>(
    `window.inlineCoreFailureHarness.loadDraft()`,
  )
  if (restoredDraft !== draftText) {
    throw new Error(
      `Recovered owner did not hydrate durable state: ${JSON.stringify(restoredDraft)}`,
    )
  }
  await page.evaluate(
    `window.inlineCoreFailureHarness.clearDraft()`,
  )
  const errors = await page.evaluate<string[]>(
    `window.inlineCoreFailureHarness.errors()`,
  )
  if (errors.length > 0) {
    throw new Error(
      `Inline core recovery produced browser errors: ${JSON.stringify(errors)}`,
    )
  }
  await page.evaluate(`window.inlineCoreFailureHarness.detach()`)

  console.log(
    JSON.stringify(
      {
        firstOwner,
        recoveredOwner,
        failure,
        terminalStart,
        restoredDraft,
        runtimeErrors: errors,
      },
      null,
      2,
    ),
  )
} finally {
  browser.close()
  await page.close()
}
