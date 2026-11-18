import { Method } from "@inline-chat/protocol/core"
import { describe, it } from "vitest"
import { DbObjectKind } from "../database/models"
import type { InlinePersistenceOperation } from "../database/persistence"
import { CoreHarness } from "./core-harness"
import type { CrashRule } from "./crashable-disk"

/**
 * Run one core scenario under each fault in the matrix of `docs/testing.md`.
 *
 * A scenario says how to set up the model, how to perform its intent, and
 * what must be true afterwards. A fault case arms a failure around the
 * intent: a lost acknowledgement, a duplicate, a sequence gap, a crash at a
 * commit checkpoint, a dropped connection, a sign-out with the intent
 * pending. The runner boots a real core against the server model, applies
 * the fault, restarts the core when the fault killed it, heals the network
 * and hands the result to the scenario's `verify`.
 *
 * Use it from a test file:
 *
 *     describeFaultMatrix(sendTextScenario)
 */

export type FaultOutcome =
  /** The intent reaches the server exactly once and the replica converges. */
  | "applied-once"
  /** The intent never became durable, so nothing may exist anywhere. */
  | "never-accepted"
  /** The session ended first: the server must never see the intent. */
  | "never-sent"

export type FaultContext = {
  readonly harness: CoreHarness
  /** Scenario-owned state, set by `act`. */
  state: Record<string, unknown>
}

export type FaultCase = {
  id: string
  /** The row of the fault matrix in `docs/testing.md` this case covers. */
  row: string
  outcome: FaultOutcome
  /** Crash the first process at a storage checkpoint. */
  crashRule?: CrashRule
  /** After connecting, before the intent. */
  before?: (context: FaultContext) => Promise<void> | void
  /** Right after the intent was started. */
  after?: (context: FaultContext) => Promise<void> | void
  /** After the scenario's `verify`: fault-specific checks on the healed run. */
  afterVerify?: (context: FaultContext) => Promise<void> | void
}

export type FaultScenario = {
  name: string
  /** Shape the server model before the core boots. */
  setup: (context: FaultContext) => void
  /** Start the intent. Do not await its settlement; faults may stall it. */
  act: (context: FaultContext) => Promise<void> | void
  /** Assert the end state for this fault's expected outcome. */
  verify: (context: FaultContext, fault: FaultCase) => Promise<void> | void
}

const writesPendingIntent = (operations: readonly InlinePersistenceOperation[]) =>
  operations.some(
    (operation) =>
      operation.type === "put" &&
      operation.object.kind === DbObjectKind.PendingTransaction &&
      operation.object.status === "pending",
  )

const removesPendingIntent = (operations: readonly InlinePersistenceOperation[]) =>
  operations.some(
    (operation) =>
      operation.type === "delete" && operation.kind === DbObjectKind.PendingTransaction,
  )

const isMutationRpc = (method: Method) =>
  method !== Method.GET_UPDATES &&
  method !== Method.GET_UPDATES_STATE &&
  method !== Method.RESERVE_CHAT_IDS &&
  method !== Method.GET_CHAT &&
  method !== Method.GET_CHAT_HISTORY

/** The matrix. Each case names the `testing.md` row it stands for. */
export const faultMatrix: readonly FaultCase[] = [
  {
    id: "no fault",
    row: "baseline",
    outcome: "applied-once",
  },
  {
    id: "acknowledgement lost after the server applied",
    row: "The acknowledgement is lost after the server applied the request.",
    outcome: "applied-once",
    before: ({ harness }) => {
      let armed = true
      harness.process.endpoint.interceptor = (frame) => {
        if (!armed || frame.kind !== "result") return "deliver"
        armed = false
        return "drop-and-disconnect"
      }
    },
  },
  {
    id: "connection lost before the server's ack",
    row: "The connection drops mid-request and comes back (request applied, nothing came back).",
    outcome: "applied-once",
    before: ({ harness }) => {
      let armed = true
      harness.process.endpoint.interceptor = (frame) => {
        if (!armed || frame.kind !== "ack") return "deliver"
        armed = false
        return "drop-and-disconnect"
      }
    },
  },
  {
    id: "request lost on a dying connection",
    row: "The connection drops mid-request and comes back (request never arrived).",
    outcome: "applied-once",
    before: ({ harness }) => {
      harness.process.transport.dropNextClientFrame(
        (message) =>
          message.body.oneofKind === "rpcCall" && isMutationRpc(message.body.rpcCall.method),
      )
    },
    after: async ({ harness }) => {
      await harness.settle()
      await harness.process.transport.disconnect("request-lost")
    },
  },
  {
    id: "every frame duplicated",
    row: "The same update arrives twice.",
    outcome: "applied-once",
    before: ({ harness }) => {
      harness.process.endpoint.interceptor = (frame) =>
        frame.kind === "push" || frame.kind === "result" ? "duplicate" : "deliver"
    },
  },
  {
    id: "out-of-order updates with a sequence gap",
    row: "Updates arrive out of order; a sequence gap appears.",
    outcome: "applied-once",
    before: ({ harness }) => {
      harness.process.transport.hold()
    },
    after: async ({ harness }) => {
      const { model } = harness
      const chatId = Array.from(model.chats.keys())[0]
      const other = Array.from(model.users.keys()).find((id) => id !== model.selfUserId)
      if (chatId == null || other == null) throw new Error("Scenario needs a chat and another user")
      await harness.settle()
      model.postMessage({ chatId, fromId: other, text: "gap one" })
      model.postMessage({ chatId, fromId: other, text: "gap two" })
      const held = harness.process.transport.held()
      await harness.process.transport.release(held.map((_, index) => index).reverse())
    },
  },
  {
    id: "offline while sending, then online",
    row: "The connection drops mid-request and comes back; the device sleeps and wakes.",
    outcome: "applied-once",
    before: async ({ harness }) => {
      await harness.settleUntil(harness.process.client.connection.setNetworkAvailable(false))
    },
    after: async ({ harness }) => {
      await harness.clock.advance(60_000)
      await harness.settleUntil(harness.process.client.connection.systemDidWake())
      await harness.settleUntil(harness.process.client.connection.setNetworkAvailable(true))
    },
  },
  {
    id: "crash before the intent commit",
    row: "The process dies before the intent commit.",
    outcome: "never-accepted",
    crashRule: { phase: "before-commit", when: writesPendingIntent },
  },
  {
    id: "crash after the intent commit, before send",
    row: "The process dies after the intent commit and before send.",
    outcome: "applied-once",
    crashRule: { phase: "after-commit", when: writesPendingIntent },
  },
  {
    id: "crash after send, before the acknowledgement",
    row: "The process dies after send and before the acknowledgement.",
    outcome: "applied-once",
    before: ({ harness, state }) => {
      // Count from before the intent: a connected core sends it in the same
      // turn it commits, so it has usually reached the server by `after`.
      state.rpcsBeforeIntent = harness.model.rpcLog.length
      harness.process.endpoint.interceptor = (frame) =>
        frame.kind === "result" || frame.kind === "ack" ? "drop" : "deliver"
    },
    after: async ({ harness, state }) => {
      const from = state.rpcsBeforeIntent as number
      await harness.runUntil(
        () => harness.model.rpcLog.slice(from).some((entry) => isMutationRpc(entry.method)),
        { description: "the server applies the request" },
      )
      // The checkpoint this row names: applied on the server, still pending here.
      if (harness.pendingIntents() !== 1) {
        throw new Error(`Expected the intent pending at the crash, found ${harness.pendingIntents()}`)
      }
      harness.crash()
      state.rpcsAtCrash = harness.model.rpcLog.length
    },
    afterVerify: ({ harness, state }) => {
      // The new process restored the intent and sent it again; the server's
      // dedupe (verified above: one message) made the second send harmless.
      const resent = harness.model.rpcLog
        .slice(state.rpcsAtCrash as number)
        .some((entry) => isMutationRpc(entry.method))
      if (!resent) throw new Error("The restored intent was never sent again after the restart")
    },
  },
  {
    id: "crash while committing the result",
    row: "The process dies during an update batch (the result's commit).",
    outcome: "applied-once",
    crashRule: { phase: "before-commit", when: removesPendingIntent },
  },
  {
    id: "sign-out with the intent pending",
    row: "The user signs out with intents pending.",
    outcome: "never-sent",
    before: async ({ harness }) => {
      await harness.settleUntil(harness.process.client.connection.setNetworkAvailable(false))
    },
    after: async ({ harness }) => {
      await harness.settle()
      await harness.settleUntil(harness.process.client.stopSession())
      await harness.settleUntil(harness.process.client.connection.setNetworkAvailable(true))
      await harness.clock.advance(30_000)
    },
  },
]

/** Run `scenario` under one fault and return the context for inspection. */
export const runFaultCase = async (
  scenario: FaultScenario,
  fault: FaultCase,
): Promise<void> => {
  const harness = CoreHarness.create()
  const context: FaultContext = { harness, state: {} }
  try {
    scenario.setup(context)
    await harness.boot(fault.crashRule ? { crashRule: fault.crashRule } : {})
    await harness.seedReplicaFromModel()
    await harness.runUntil(() => harness.connected(), { description: "first connection" })
    await harness.settle()

    await fault.before?.(context)
    await scenario.act(context)
    await harness.settle()
    await fault.after?.(context)
    await harness.settle()

    if (fault.outcome !== "never-sent") {
      // A fault that killed the process: start a new one on the same disk.
      if (!harness.isRunning) await harness.boot()
      else if (!harness.process.store.alive) await harness.restart({ crash: true })
    }
    if (harness.disk.crashes.length === 0 && fault.crashRule) {
      throw new Error(`Fault "${fault.id}" never reached its crash checkpoint`)
    }
    if (fault.outcome !== "never-sent") await harness.heal()
    await scenario.verify(context, fault)
    await fault.afterVerify?.(context)
  } catch (error) {
    if (error instanceof Error) {
      error.message +=
        `\n\nFault: ${fault.id}\nCore log (last events):\n  ` +
        harness.recentLogs(30).join("\n  ")
    }
    throw error
  } finally {
    await harness.dispose()
  }
}

/**
 * One test per fault case. `expectedFailures` maps a fault ID to the reason
 * it currently fails (a recorded core bug); those run as `it.fails`.
 */
export const describeFaultMatrix = (
  scenario: FaultScenario,
  options: { faults?: readonly FaultCase[]; expectedFailures?: Record<string, string> } = {},
) =>
  describe(`${scenario.name} under the fault matrix`, () => {
    for (const fault of options.faults ?? faultMatrix) {
      const knownFailure = options.expectedFailures?.[fault.id]
      const test = knownFailure ? it.fails : it
      test(knownFailure ? `${fault.id} (known: ${knownFailure})` : fault.id, () =>
        runFaultCase(scenario, fault),
      )
    }
  })
