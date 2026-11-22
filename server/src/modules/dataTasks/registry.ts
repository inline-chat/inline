import type { DataTask } from "./dataTask"
import closeGrandfatheredBots from "./tasks/2026-11-21-close-grandfathered-bots"

/** Every data task, oldest first. Keep finished tasks: the ledger and `revert` refer to them by ID. */
export const dataTasks: readonly DataTask[] = [closeGrandfatheredBots]

export function findDataTask(id: string): DataTask | undefined {
  return dataTasks.find((task) => task.id === id)
}
