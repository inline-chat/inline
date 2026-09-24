import { BackgroundWork } from "../lifecycle/backgroundWork"

/**
 * Tracks database-backed work deliberately started after a WebSocket has been
 * admitted. It remains separate from application-owned work so connection
 * shutdown does not wait for unrelated background jobs.
 */
export const connectionBackgroundWork = new BackgroundWork()
