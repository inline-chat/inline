export type FunctionContext = {
  currentUserId: number
  currentSessionId: number
  /** Present for realtime RPCs whose authorization is bound to one socket. */
  currentConnectionId?: string
  /**
   * Whether the authenticated account is a bot, when the entry point knows it (realtime sockets
   * and the Bot API do). Undefined means unknown: look the user up rather than assume a person.
   */
  isBot?: boolean
  /** V3 application deadline. Read-only work checks it between database stages. */
  signal?: AbortSignal
}
