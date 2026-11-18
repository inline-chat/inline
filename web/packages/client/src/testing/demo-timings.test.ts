import type { ChatID, UserID } from "@inline/ids"
import type { DialogRow } from "@inline/core-protocol"
import { Log } from "@inline/log"
import { describe, expect, it } from "vitest"
import { CoreHost } from "../host/core-host"
import { FakeDisk, TestContext } from "../host/__tests__/fixtures"
import type { DemoScale } from "./demo-account"
import { DEMO_USER_ID } from "./demo-protocol"
import { DemoWorld } from "./demo-world"

/**
 * How long each demo scale takes to become usable, in real time, on the real
 * core over in-memory SQLite. Opt in: `DEMO_TIMINGS=1 bunx vitest run
 * src/testing/demo-timings.test.ts` (small, medium and large; the large one
 * takes a few seconds). Numbers go to the console.
 */

const enabled = typeof process !== "undefined" && process.env.DEMO_TIMINGS === "1"

/** Resolve once `predicate` holds after a message from the core. */
const when = (ui: TestContext, host: CoreHost, predicate: () => boolean) =>
  new Promise<void>((resolve, reject) => {
    if (predicate()) return resolve()
    const timeout = setTimeout(() => {
      unsubscribe()
      reject(new Error("timed out"))
    }, 120_000)
    const unsubscribe = host.subscribe(() => {
      queueMicrotask(() => {
        if (!predicate()) return
        clearTimeout(timeout)
        unsubscribe()
        resolve()
      })
    })
    void ui
  })

const mediaCost = (world: DemoWorld) => {
  const started = performance.now()
  world.server?.transfers.file("dp_123_800x600")
  return Math.round((performance.now() - started) * 10) / 10
}

const measure = async (scale: DemoScale) => {
  const started = performance.now()
  const elapsed = () => Math.round(performance.now() - started)
  const world = new DemoWorld({ seed: 1, scale, storage: "memory", logger: new Log("Demo", { sink: false }) })
  const disk = new FakeDisk()
  const host = new CoreHost({
    buildId: "timings",
    openStorage: () => disk.storage(),
    createTransport: () => world.transport,
    logger: new Log("Core", { sink: false }),
  })
  const ui = new TestContext(host)
  ui.post({ kind: "session", action: "start", session: { userId: DEMO_USER_ID as UserID, token: "demo" } })
  ui.subscribeTo(1, { kind: "core" })
  ui.subscribeTo(2, { kind: "sidebar", mode: "inbox" })
  await world.ready
  const seeded = elapsed()
  await when(ui, host, () => ui.list(2).length > 0)
  const sidebar = elapsed()
  const first = (ui.rows(2)[0] as DialogRow).chatId as ChatID
  const opened = performance.now()
  ui.subscribeTo(3, { kind: "chatWindow", chatId: first, anchor: "latest" })
  await when(ui, host, () => ui.list(3).length > 0)
  const firstRows = Math.round(performance.now() - opened)
  // What the server's latest page holds (seeded holes are skipped).
  const count = world.server?.lazy(BigInt(first))?.idsBefore(undefined, 50).length ?? 0
  await when(ui, host, () => ui.list(3).length >= count)
  const window = Math.round(performance.now() - opened)
  await host.idle()
  const result = {
    scale,
    seededMs: seeded,
    sidebarMs: sidebar,
    firstRowsMs: firstRows,
    latestPageMs: window,
    sidebarRows: ui.list(2).length,
    heapMB: Math.round(process.memoryUsage().heapUsed / 1e6),
    materializedChats: world.server?.materializedChats() ?? -1,
    worldTimings: world.status().timings,
    // Making one photo's largest size, its stripped preview and a sidebar's worth of encodes.
    mediaMs: mediaCost(world),
  }
  const stopping = performance.now()
  await host.shutdown()
  await world.dispose()
  process.stderr.write(`stop ${Math.round(performance.now() - stopping)} total ${elapsed()}\n`)
  return result
}

describe.skipIf(!enabled)("demo timings", () => {
  it("measures each scale", { timeout: 300_000 }, async () => {
    const results = []
    for (const scale of ["small", "medium", "large"] as const) {
      const result = await measure(scale)
      process.stderr.write(`${JSON.stringify(result)}\n`)
      results.push(result)
    }
    for (const result of results) expect(result.sidebarRows).toBeGreaterThan(0)
  })
})
