export type ActiveInlineThreadRoute = {
  accountId: string
  sessionKey: string
  sourceChatId: bigint
  sourceMessageId: bigint
  sourceMessageSid?: string
  parentPeer: { kind: "direct" | "group"; id: string }
  threadId?: bigint | undefined
  adoption?: Promise<void>
  onThreadAdopted: (threadId: bigint) => Promise<void>
}

// Like OpenClaw's Discord active-turn route: this is dispatch-scoped, never a
// "latest thread" fallback. Share it across lazy plugin entry bundles.
const key = Symbol.for("openclaw.inlineActiveThreadRoutes")
const globals = globalThis as Record<PropertyKey, unknown>
const routes = (globals[key] ??= new Set<ActiveInlineThreadRoute>()) as Set<ActiveInlineThreadRoute>

export function beginInlineActiveThreadRoute(route: ActiveInlineThreadRoute): () => void {
  routes.add(route)
  return () => { routes.delete(route) }
}

export function getInlineActiveThreadRoute(params: {
  accountId: string
  sessionKey?: string | null | undefined
  sourceMessageId?: string
}): ActiveInlineThreadRoute | undefined {
  if (!params.sessionKey) return undefined
  const matches = [...routes].filter((route) =>
    route.accountId === params.accountId && route.sessionKey === params.sessionKey &&
    (!params.sourceMessageId || String(route.sourceMessageId) === params.sourceMessageId ||
      route.sourceMessageSid === params.sourceMessageId),
  )
  return matches.length === 1 ? matches[0] : undefined
}

export async function adoptInlineActiveThread(params: {
  accountId: string
  sessionKey?: string | null | undefined
  parentChatId: bigint
  parentMessageId?: bigint
  threadId: bigint
}): Promise<void> {
  if (params.parentMessageId == null) return
  const route = getInlineActiveThreadRoute({
    ...params,
    sourceMessageId: String(params.parentMessageId),
  })
  if (!route || route.sourceChatId !== params.parentChatId) return
  if (route.adoption) await route.adoption
  if (route.threadId != null) return
  // Publish one transition before invoking callbacks, and expose the new route
  // only after all old-chat operations have drained. A failed transition can be
  // retried instead of poisoning every later action in the turn.
  const adoption = Promise.resolve().then(async () => {
    await route.onThreadAdopted(params.threadId)
    route.threadId = params.threadId
  })
  route.adoption = adoption
  try {
    await adoption
  } catch (error) {
    if (route.adoption === adoption) delete route.adoption
    throw error
  }
}
