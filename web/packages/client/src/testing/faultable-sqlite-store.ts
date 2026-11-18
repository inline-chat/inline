import { createSqliteMemoryPersistenceStore } from "../database/sqlite/openers"

/**
 * An in-memory SQLite store for tests that can fail a write transaction and
 * count transactions. A failure is raised just before COMMIT, so the store
 * rolls the whole transaction back, as a real disk or quota error would.
 */
export const createFaultableSqliteStore = () => {
  let nextFailure: { error: unknown } | undefined
  let transactionCount = 0
  const store = createSqliteMemoryPersistenceStore({
    onWriteCheckpoint: ({ phase }) => {
      if (phase !== "before-commit") return
      transactionCount += 1
      if (!nextFailure) return
      const { error } = nextFailure
      nextFailure = undefined
      throw error
    },
  })
  return {
    store,
    failNextWrite(error: unknown) {
      nextFailure = { error }
    },
    get transactionCount() {
      return transactionCount
    },
  }
}
