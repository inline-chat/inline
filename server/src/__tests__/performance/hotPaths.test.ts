import { afterAll, beforeAll, test } from "bun:test"
import { db } from "@in/server/db"
import { setupTestDatabase, teardownTestDatabase } from "../database"
import { scenarios, type ScenarioSpec } from "./catalog"
import { assertQueryBudget, measureOperation } from "./measure"
import { observeScenarioWork } from "./observe"
import { prepareScenario } from "./scenarios"

const background = observeScenarioWork()
beforeAll(setupTestDatabase)
afterAll(async () => {
  try { await background.close() } finally { await teardownTestDatabase() }
})

// One recovery-index upsert per durable journal write. These allowances follow
// the fixture's semantics; do not infer them from the measured query count.
function recoveryWrites(spec: ScenarioSpec): number {
  switch (spec.kind) {
    case "sendDm": return spec.variant === "retry" ? 0 : spec.variant === "closed" ? 2 : 1
    case "sendThread": return spec.variant === "reply" ? 2 : 1
    case "enqueue": return spec.size
    case "read": return spec.variant === "noop" ? 0 : 1
    default: return 0
  }
}

for (const mode of ["0", "1"] as const) {
  for (const spec of scenarios) {
    const name = `${spec.id} (${mode === "0" ? "standalone" : "distributed"})`
    test(`${name}: behavior and database command budget`, async () => {
      await background.drain()
      const previousMode = process.env["REALTIME_DISTRIBUTED"]
      process.env["REALTIME_DISTRIBUTED"] = mode
      try {
        const operation = await prepareScenario(spec)
        await background.drain()
        const sample = await measureOperation(db.$client.options, operation.run, background.drain)
        await operation.verify()
        await background.drain()
        assertQueryBudget(name, sample, spec.maxCommands + (mode === "1" ? recoveryWrites(spec) : 0))
      } finally {
        try { await background.drain() } finally {
          if (previousMode === undefined) delete process.env["REALTIME_DISTRIBUTED"]
          else process.env["REALTIME_DISTRIBUTED"] = previousMode
        }
      }
    })
  }
}
