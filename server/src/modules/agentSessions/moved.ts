/**
 * Thrown inside a work's transaction when the session moved to another chat
 * after it was read but before it was locked. The caller retries with the
 * session's new chat.
 */
export class AgentSessionMovedError extends Error {
  constructor() {
    super("agent session moved to another chat")
    this.name = "AgentSessionMovedError"
  }
}

/** A work moves at most once per subthread hop, so a few retries suffice. */
export const MAX_MOVE_RETRIES = 3
