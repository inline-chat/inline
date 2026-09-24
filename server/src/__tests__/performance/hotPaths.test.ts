import { afterAll, beforeAll, test } from "bun:test"
import { db } from "@in/server/db"
import { setupTestDatabase, teardownTestDatabase } from "../database"
import { scenarios } from "./catalog"
import { assertQueryBudget, measureOperation } from "./measure"
import { observeScenarioWork } from "./observe"
import { prepareScenario } from "./scenarios"

const background = observeScenarioWork()
beforeAll(setupTestDatabase)
afterAll(async () => {
  try { await background.close() } finally { await teardownTestDatabase() }
})

for (const spec of scenarios) {
  test(`${spec.id}: behavior and database command budget`, async () => {
    await background.drain()
    const operation = await prepareScenario(spec)
    await background.drain()
    const sample = await measureOperation(db.$client.options, operation.run, background.drain)
    await operation.verify()
    await background.drain()
    assertQueryBudget(spec.id, sample, spec.maxCommands)
  })
}
