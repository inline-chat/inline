export {}

import { ChromeDevtoolsPage } from "./ChromeDevtoolsPage"

const debuggerOrigin = process.argv[2] ?? "http://127.0.0.1:9223"
const appOrigin = process.argv[3] ?? "http://127.0.0.1:8001"

const page = await ChromeDevtoolsPage.open(debuggerOrigin)

try {
  await page.navigate(appOrigin)
  const result = await page.evaluate(`(async () => {
    const harness = await import("/src/testing/auth/AuthSessionBrowserHarness.ts")
    return await harness.runAuthSessionBrowserHarness()
  })()`)
  console.log(JSON.stringify(result, null, 2))
} finally {
  await page.close()
}
