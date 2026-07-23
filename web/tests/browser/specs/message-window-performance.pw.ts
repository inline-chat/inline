import { expect, test } from "@playwright/test"
import type { MessageWindowBenchmarkResult } from "../../../src/testing/benchmarks/MessageWindowBenchmark"

test("selectively hydrates a bounded window from 50,000 persisted messages", async ({
  page,
}, testInfo) => {
  test.setTimeout(60_000)
  await page.goto("/")

  const result = await page.evaluate<MessageWindowBenchmarkResult>(async () => {
    const modulePath =
      "/src/testing/benchmarks/MessageWindowBenchmark.ts"
    const benchmark = await import(modulePath)
    return benchmark.runMessageWindowBenchmark({
      environment: "browser-indexeddb",
    })
  })

  await testInfo.attach("message-window-benchmark.json", {
    body: JSON.stringify(result, null, 2),
    contentType: "application/json",
  })

  expect(result.totalMessages).toBe(50_000)
  expect(result.latest).toMatchObject({
    rowsRead: 60,
    residentMessages: 60,
  })
  expect(result.around).toMatchObject({
    found: true,
    residentMessages: 60,
  })
  expect(result.prepend).toMatchObject({
    rowsRead: 100,
    residentMessages: 160,
  })
  expect(result.release.residentMessages).toBe(0)
  expect(result.rehydrate).toMatchObject({
    rowsRead: 60,
    residentMessages: 60,
  })

  for (const elapsedMs of [
    result.latest.elapsedMs,
    result.around.elapsedMs,
    result.prepend.elapsedMs,
    result.release.elapsedMs,
    result.rehydrate.elapsedMs,
  ]) {
    expect(elapsedMs).toBeLessThan(500)
  }
  expect(
    result.measuredLongTasks.filter((entry) => entry.duration >= 250),
  ).toEqual([])
})
