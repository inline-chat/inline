export type ScenarioSpec = {
  id: string
  kind: "sendDm" | "sendThread" | "getChats" | "history" | "replay" | "checkpoint" | "enqueue" | "dialog" | "read"
  size: number
  variant?: "closed" | "retry" | "receiptRetry" | "reply" | "empty" | "noop"
  maxCommands: number
}

// These are reviewed upper bounds for complete operations, including tracked
// detached work and transaction control. They describe current costs, not targets.
// Fixture or semantic changes require a version bump before comparing timings.
// Version 2 accepts durable submission receipts and current-authority replay
// checks. The receipt-retry fixture is explicitly warm after successful submit.
export const scenarioVersion = 2
export const scenarios: readonly ScenarioSpec[] = [
  { id: "send.dm.open", kind: "sendDm", size: 1, maxCommands: 27 },
  { id: "send.dm.closed", kind: "sendDm", size: 1, variant: "closed", maxCommands: 43 },
  // Existing pre-ledger random-ID row: preserve the current-access fallback.
  { id: "send.dm.retry", kind: "sendDm", size: 1, variant: "retry", maxCommands: 13 },
  { id: "send.dm.receipt-retry.warm", kind: "sendDm", size: 1, variant: "receiptRetry", maxCommands: 9 },
  ...[1, 10, 100].map((size): ScenarioSpec => ({ id: `send.public.${size}`, kind: "sendThread", size, maxCommands: 33 + size })),
  ...[1, 10, 100].map((size): ScenarioSpec => ({ id: `send.reply.${size}`, kind: "sendThread", size, variant: "reply", maxCommands: 68 + 7 * size })),
  ...[1, 10, 100].map((size): ScenarioSpec => ({ id: `getChats.${size}`, kind: "getChats", size, maxCommands: 11 })),
  { id: "history.50", kind: "history", size: 50, maxCommands: 7 },
  { id: "updates.replay.empty", kind: "replay", size: 0, variant: "empty", maxCommands: 7 },
  { id: "updates.replay.message", kind: "replay", size: 1, maxCommands: 23 },
  { id: "updates.checkpoint", kind: "checkpoint", size: 1, maxCommands: 6 },
  ...[1, 10, 100].map((size): ScenarioSpec => ({ id: `updates.enqueue.${size}`, kind: "enqueue", size, maxCommands: 4 * size + 2 })),
  ...[1, 10, 100].map((size): ScenarioSpec => ({ id: `dialogs.noop.${size}`, kind: "dialog", size, maxCommands: size + 5 })),
  { id: "read.advance", kind: "read", size: 1, maxCommands: 12 },
  { id: "read.noop", kind: "read", size: 1, variant: "noop", maxCommands: 5 },
]

export const defaultScenarios = ["send.dm.open", "send.public.100", "getChats.100", "updates.replay.empty", "updates.enqueue.100"]

export function selectScenarios(ids: readonly string[]): ScenarioSpec[] {
  const unique = [...new Set(ids)]
  if (!unique.length) throw new Error("Select at least one benchmark scenario")
  return unique.map((id) => {
    const scenario = scenarios.find((entry) => entry.id === id)
    if (!scenario) throw new Error(`Unknown backend scenario: ${id}. Use --list.`)
    return scenario
  })
}
