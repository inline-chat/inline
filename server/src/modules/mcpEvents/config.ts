// Capture is always transactional after migration. Expose the source only once
// all reaction writers run that version; disabling also fences delivery.
export const reactionEventNames = ["reaction.added", "reaction.removed"] as const
export const isReactionEvent = (name: string): boolean => reactionEventNames.some((value) => value === name)
export const reactionEventsEnabled = (): boolean => process.env["MCP_REACTION_EVENTS_ENABLED"] === "true"
