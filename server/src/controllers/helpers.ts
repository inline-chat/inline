/** Caller identity passed to the retained `src/methods` business operations. */
export type HandlerContext = {
  currentUserId: number
  currentSessionId: number
  ip: string | undefined
}

/** Context for retained `src/methods` operations that run before sign-in. */
export type UnauthenticatedHandlerContext = {
  ip: string | undefined
  source?: string
}
