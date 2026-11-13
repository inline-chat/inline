// Generated from packages/agent-activity/src by `bun run sync` there. Edit the source, not this copy.
/** How an agent presents its work (`AgentOutputMode`). */
export type OutputMode = "detailed" | "friendly"

/** `AgentOutputMode` values: 0 unspecified, 1 detailed, 2 friendly. */
const DETAILED = 1
const FRIENDLY = 2

/**
 * The mode for one thread: the participation's override when it has one,
 * else the bot's default; unspecified means Detailed (proto/core.proto,
 * AgentSettings.default_output_mode).
 */
export function resolveOutputMode(defaultMode: number | undefined, threadOverride?: number | undefined): OutputMode {
  const pick = (mode: number | undefined) => (mode === DETAILED ? "detailed" : mode === FRIENDLY ? "friendly" : undefined)
  return pick(threadOverride) ?? pick(defaultMode) ?? "detailed"
}
