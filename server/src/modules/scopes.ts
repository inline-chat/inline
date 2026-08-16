import type { DbChat } from "@in/server/db/schema"

/** Official product scope. Persist owners on their native rows; do not create a parallel scope entity. */
export type ScopeRef = { type: "space"; id: number } | { type: "user"; id: number }

type ScopedChat = Pick<DbChat, "spaceId" | "createdBy">

export function scopeFromChat(chat: ScopedChat): ScopeRef | null {
  if (chat.spaceId !== null) {
    return { type: "space", id: chat.spaceId }
  }

  if (chat.createdBy !== null) {
    return { type: "user", id: chat.createdBy }
  }

  return null
}
