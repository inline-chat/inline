// A bot's hand-back needs no answer, but OpenClaw requires a group reply and
// routes its "couldn't produce a reply" notice through the outbound send when
// the agent stays silent. The monitor marks the chat while a hand-back turn
// runs so that send can drop the notice. Bundles are separate, so the marks
// live on globalThis.
const STORE_KEY = Symbol.for("inline-openclaw.quietHandBacks.v1")

function store(): Map<string, number> {
  const root = globalThis as Record<symbol, unknown>
  let marks = root[STORE_KEY] as Map<string, number> | undefined
  if (!marks) {
    marks = new Map()
    root[STORE_KEY] = marks
  }
  return marks
}

function markKey(accountId: string, chatId: string | bigint): string {
  return `${accountId}:${String(chatId)}`
}

/** Marks a chat for the length of a hand-back turn; call the result when it ends. */
export function beginInlineQuietHandBack(accountId: string, chatId: string | bigint): () => void {
  const key = markKey(accountId, chatId)
  const marks = store()
  marks.set(key, (marks.get(key) ?? 0) + 1)
  let ended = false
  return () => {
    if (ended) return
    ended = true
    const remaining = (marks.get(key) ?? 1) - 1
    if (remaining > 0) marks.set(key, remaining)
    else marks.delete(key)
  }
}

export function isInlineQuietHandBack(accountId: string, chatId: string | bigint): boolean {
  return (store().get(markKey(accountId, chatId)) ?? 0) > 0
}
