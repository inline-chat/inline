export type FunctionContext = {
  currentUserId: number
  currentSessionId: number
  /** Present for realtime RPCs whose authorization is bound to one socket. */
  currentConnectionId?: string
  /** Authenticated bot calls use the existing edit path for silent streaming updates. */
  isBot?: boolean
}
