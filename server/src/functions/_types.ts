export type FunctionContext = {
  currentUserId: number
  currentSessionId: number
  /** Authenticated bot calls use the existing edit path for silent streaming updates. */
  isBot?: boolean
}
