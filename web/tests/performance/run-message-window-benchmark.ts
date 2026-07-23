export {}

import { ChromeDevtoolsPage } from "../browser/ChromeDevtoolsPage"

const debuggerOrigin = process.argv[2] ?? "http://127.0.0.1:9223"
const appOrigin = process.argv[3] ?? "http://127.0.0.1:8001"

const page = await ChromeDevtoolsPage.open(debuggerOrigin)

try {
  await page.navigate(appOrigin)
  const result = await page.evaluate(`(async () => {
      const benchmark = await import("/src/testing/benchmarks/MessageWindowBenchmark.ts")
      return await benchmark.runMessageWindowBenchmark({
        environment: "browser-indexeddb"
      })
    })()`)
  console.log(JSON.stringify(result, null, 2))
} finally {
  await page.close()
}
