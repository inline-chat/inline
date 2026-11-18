import type { InputPeer, Peer } from "@inline-chat/protocol/core"

/**
 * Direct messages on the wire. The base server model knows thread peers
 * only; the real server names a direct message by the other user, in both
 * directions. The demo model keeps every chat as a thread inside and maps
 * at its edges:
 *
 * - `inputPeersToChats`: a request's `InputPeer` user (and a bucket naming
 *   one) becomes the chat with that user;
 * - `chatPeersToUsers`: every `Peer` chat of a direct message in a result or
 *   a push becomes the user it is with.
 *
 * Both copy on write (stored objects are never mutated) and skip byte arrays.
 */

type Walk = (value: unknown) => unknown

const walker = (replace: (value: Record<string, unknown>) => unknown | undefined): Walk => {
  const walk: Walk = (value) => {
    if (value === null || typeof value !== "object" || ArrayBuffer.isView(value)) return value
    if (Array.isArray(value)) {
      let copy: unknown[] | undefined
      for (let index = 0; index < value.length; index += 1) {
        const next = walk(value[index])
        if (next !== value[index]) {
          copy ??= value.slice()
          copy[index] = next
        }
      }
      return copy ?? value
    }
    const record = value as Record<string, unknown>
    const replaced = replace(record)
    if (replaced !== undefined) return replaced
    let copy: Record<string, unknown> | undefined
    for (const key of Object.keys(record)) {
      const next = walk(record[key])
      if (next !== record[key]) {
        copy ??= { ...record }
        copy[key] = next
      }
    }
    return copy ?? value
  }
  return walk
}

const peerType = (value: Record<string, unknown>) => {
  const type = value.type as { oneofKind?: unknown; chat?: { chatId?: unknown }; user?: { userId?: unknown } } | undefined
  if (type == null || typeof type !== "object" || Object.keys(value).length !== 1) return undefined
  return type
}

/** Requests: `InputPeer` users with a direct message become that chat. */
export const inputPeersToChats = <T>(value: T, chatForUser: ReadonlyMap<bigint, bigint>): T =>
  walker((record) => {
    const type = peerType(record)
    if (type?.oneofKind !== "user" || typeof type.user?.userId !== "bigint") return undefined
    const chatId = chatForUser.get(type.user.userId)
    return chatId == null ? undefined : ({ type: { oneofKind: "chat", chat: { chatId } } } satisfies InputPeer)
  })(value) as T

/** Results and pushes: `Peer` chats that are direct messages become the other user. */
export const chatPeersToUsers = <T>(value: T, userForChat: ReadonlyMap<bigint, bigint>): T =>
  walker((record) => {
    const type = peerType(record)
    if (type?.oneofKind !== "chat" || typeof type.chat?.chatId !== "bigint") return undefined
    const userId = userForChat.get(type.chat.chatId)
    return userId == null ? undefined : ({ type: { oneofKind: "user", user: { userId } } } satisfies Peer)
  })(value) as T

export const userPeer = (userId: bigint): Peer => ({ type: { oneofKind: "user", user: { userId } } })
