import { afterEach, describe, expect, test } from "bun:test"
import type { Transaction } from "./types"
import {
  installPostCommitHooks,
  maxConcurrentPostCommitHooks,
  maxQueuedPostCommitHooks,
  registerPostCommitHook,
  type PostCommitHook,
  waitForPostCommitHooks,
} from "./commitHooks"

type FakeDatabase = {
  transaction: <T>(callback: (tx: Transaction) => Promise<T>) => Promise<T>
}

const createFakeDatabase = (): FakeDatabase => {
  const createTransaction = (): Transaction => {
    const transaction = async <T>(callback: (tx: Transaction) => Promise<T>): Promise<T> => callback(createTransaction())
    return { transaction } as unknown as Transaction
  }
  const database: FakeDatabase = {
    transaction: async <T>(callback: (tx: Transaction) => Promise<T>): Promise<T> => callback(createTransaction()),
  }
  return installPostCommitHooks(database)
}

const occupyWorkers = async (database: FakeDatabase) => {
  let started = 0
  let startWorkers!: () => void
  const workersStarted = new Promise<void>((resolve) => { startWorkers = resolve })
  let releaseWorkers!: () => void
  const workersReleased = new Promise<void>((resolve) => { releaseWorkers = resolve })

  await database.transaction(async (tx) => {
    for (let index = 0; index < maxConcurrentPostCommitHooks; index += 1) {
      registerPostCommitHook(tx, `blocker:${index}`, {
        run: async () => {
          started += 1
          if (started === maxConcurrentPostCommitHooks) startWorkers()
          await workersReleased
        },
      })
    }
  })
  await workersStarted
  return releaseWorkers
}

class CoalescingHook implements PostCommitHook {
  constructor(
    private frontier: number,
    private readonly delivered: number[],
  ) {}

  async run() {
    this.delivered.push(this.frontier)
  }

  merge(next: PostCommitHook) {
    if (!(next instanceof CoalescingHook)) throw new Error("Unexpected hook type")
    this.frontier = Math.max(this.frontier, next.frontier)
  }
}

describe("post-commit hooks", () => {
  afterEach(async () => {
    await waitForPostCommitHooks()
  })

  test("coalesces a queued key across separately committed transactions", async () => {
    const database = createFakeDatabase()
    const releaseWorkers = await occupyWorkers(database)
    const delivered: number[] = []

    try {
      await database.transaction(async (tx) => {
        registerPostCommitHook(tx, "user:42", new CoalescingHook(1, delivered))
      })
      await database.transaction(async (tx) => {
        registerPostCommitHook(tx, "user:42", new CoalescingHook(2, delivered))
      })

      releaseWorkers()
      await waitForPostCommitHooks()
      expect(delivered).toEqual([2])
    } finally {
      releaseWorkers()
      await waitForPostCommitHooks()
    }
  })

  test("bounds queued hooks and drops only excess transient notifications", async () => {
    const database = createFakeDatabase()
    const releaseWorkers = await occupyWorkers(database)
    let delivered = 0

    try {
      await database.transaction(async (tx) => {
        for (let index = 0; index <= maxQueuedPostCommitHooks; index += 1) {
          registerPostCommitHook(tx, `user:${index}`, {
            run: async () => { delivered += 1 },
          })
        }
      })

      releaseWorkers()
      await waitForPostCommitHooks()
      expect(delivered).toBe(maxQueuedPostCommitHooks)
    } finally {
      releaseWorkers()
      await waitForPostCommitHooks()
    }
  })

  test("rejects registration against a transaction after its callback has returned", async () => {
    const database = createFakeDatabase()
    let captured: Transaction | undefined

    await database.transaction(async (tx) => {
      captured = tx
    })

    if (!captured) throw new Error("Expected a transaction to be captured")
    expect(() => registerPostCommitHook(captured!, "late", { run: async () => {} }))
      .toThrow("Post-commit hooks require a transaction created by the configured database")
  })
})
