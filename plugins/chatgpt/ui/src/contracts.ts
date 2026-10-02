export type RecordValue = Record<string, unknown>
export const isRecord = (value: unknown): value is RecordValue => value !== null && typeof value === "object" && !Array.isArray(value)
export const isId = (value: unknown): value is string => typeof value === "string" && /^[1-9]\d{0,18}$/.test(value) && BigInt(value) <= 9_223_372_036_854_775_807n
const nullableString = (value: unknown): value is string | null => value === null || typeof value === "string"

export type ThreadRef = { chatId: string; title: string }
export type Person = { userId: string; displayName: string; avatarUrl?: string }
export type Media = {
  kind: "photo" | "video" | "document" | "voice" | "nudge"
  id?: string | null
  url: string | null
  fileName?: string | null
  mimeType?: string | null
  sizeBytes?: number | null
  width?: number | null
  height?: number | null
  durationSeconds?: number | null
}
export type Message = {
  id: string
  chatId: string
  text: string
  out: boolean
  fromId: string | null
  senderDisplayName?: string
  date: string | null
  replyToMsgId: string | null
  editDate: string | null
  media: Media | null
  links: string[]
}
export type ThreadSnapshot = {
  chat: ThreadRef & { kind: "dm" | "home_thread" | "space_chat"; peer?: { displayName: string | null; userId: string | null } | null }
  messages: Message[]
  nextOffsetId: string | null
  participants?: Person[]
  details?: { emoji?: string | null; isPublic?: boolean | null; groupParticipantCount?: number }
  capabilities?: { canSend: boolean }
  monitoring?: { active: boolean; expiresAt?: string }
}
export type WidgetState = {
  version: 1
  threads: ThreadRef[]
  activeChatId: string | null
  unconfirmed: Record<string, { text: string; replyToMsgId?: string }>
}

/** Accept only a resolved, bounded thread result, never a workspace catalog. */
export function readThreadSnapshot(result: unknown): ThreadSnapshot | null {
  if (!isRecord(result) || result.isError === true || !isRecord(result.structuredContent)) return null
  const data = result.structuredContent
  if (!isRecord(data.chat) || !isId(data.chat.chatId) || typeof data.chat.title !== "string"
    || !["dm", "home_thread", "space_chat"].includes(String(data.chat.kind))
    || !Array.isArray(data.messages) || data.messages.length > 50
    || !nullableString(data.nextOffsetId) || (data.nextOffsetId !== null && !isId(data.nextOffsetId))) return null
  for (const message of data.messages) {
    if (!isRecord(message) || !isId(message.id) || message.chatId !== data.chat.chatId
      || typeof message.text !== "string" || typeof message.out !== "boolean"
      || !nullableString(message.fromId) || !nullableString(message.date)
      || !nullableString(message.replyToMsgId) || !nullableString(message.editDate)
      || !Array.isArray(message.links) || !message.links.every((link) => typeof link === "string")
      || (message.senderDisplayName !== undefined && typeof message.senderDisplayName !== "string")
      || (message.media !== null && (!isRecord(message.media)
        || !["photo", "video", "document", "voice", "nudge"].includes(String(message.media.kind))
        || !nullableString(message.media.url)))) return null
  }
  if (data.participants !== undefined && (!Array.isArray(data.participants) || !data.participants.every((person) =>
    isRecord(person) && isId(person.userId) && typeof person.displayName === "string"))) return null
  if (data.capabilities !== undefined && (!isRecord(data.capabilities) || typeof data.capabilities.canSend !== "boolean")) return null
  if (data.details !== undefined && (!isRecord(data.details)
    || (data.details.emoji !== undefined && !nullableString(data.details.emoji)))) return null
  if (data.monitoring !== undefined && (!isRecord(data.monitoring) || typeof data.monitoring.active !== "boolean"
    || (data.monitoring.expiresAt !== undefined && typeof data.monitoring.expiresAt !== "string"))) return null
  return data as unknown as ThreadSnapshot
}

export function readWidgetState(value: unknown): WidgetState {
  const empty: WidgetState = { version: 1, threads: [], activeChatId: null, unconfirmed: {} }
  if (!isRecord(value) || value.version !== 1 || !Array.isArray(value.threads)) return empty
  const threads = [...new Map(value.threads.filter((item): item is ThreadRef => isRecord(item) && isId(item.chatId) && typeof item.title === "string")
    .slice(0, 12).map(({ chatId, title }) => [chatId, { chatId, title: title.slice(0, 200) }])).values()]
  const unconfirmed: WidgetState["unconfirmed"] = {}
  if (isRecord(value.unconfirmed)) for (const thread of threads) {
    const item = value.unconfirmed[thread.chatId]
    if (isRecord(item) && typeof item.text === "string" && item.text.length <= 8000
      && (item.replyToMsgId === undefined || isId(item.replyToMsgId))) {
      unconfirmed[thread.chatId] = { text: item.text, ...(typeof item.replyToMsgId === "string" ? { replyToMsgId: item.replyToMsgId } : {}) }
    }
  }
  return { version: 1, threads, activeChatId: threads.some((item) => item.chatId === value.activeChatId) ? String(value.activeChatId) : null, unconfirmed }
}

export function rememberThread(state: WidgetState, thread: ThreadRef): WidgetState {
  if (state.activeChatId === thread.chatId && state.threads[0]?.chatId === thread.chatId && state.threads[0].title === thread.title) return state
  const threads = [{ chatId: thread.chatId, title: thread.title }, ...state.threads.filter((item) => item.chatId !== thread.chatId)].slice(0, 12)
  const unconfirmed: WidgetState["unconfirmed"] = {}
  for (const item of threads) {
    const value = state.unconfirmed[item.chatId]
    if (value) unconfirmed[item.chatId] = value
  }
  return { ...state, activeChatId: thread.chatId, threads, unconfirmed }
}

export function resolvedChatRef(result: unknown): ThreadRef | null {
  // Ask may create the thread successfully and fail to deliver the seed question.
  if (!isRecord(result) || !isRecord(result.structuredContent)
    || !isRecord(result.structuredContent.chat)) return null
  const chat = result.structuredContent.chat
  return isId(chat.chatId) && typeof chat.title === "string" ? { chatId: chat.chatId, title: chat.title } : null
}

export function mergeMessages(previous: Message[], incoming: Message[]): Message[] {
  const byId = new Map(previous.map((message) => [message.id, message]))
  for (const message of incoming) byId.set(message.id, message)
  return [...byId.values()].sort((left, right) => BigInt(left.id) < BigInt(right.id) ? -1 : 1).slice(-500)
}

/** An unfiltered recent page replaces its complete ID range, including deletions. */
export function mergeRecentMessages(previous: Message[], incoming: Message[], nextOffsetId: string | null): Message[] {
  if (nextOffsetId === null) return mergeMessages([], incoming)
  if (!incoming.length) return previous
  const oldest = incoming.reduce((id, message) => BigInt(message.id) < id ? BigInt(message.id) : id, BigInt(incoming[0]!.id))
  return mergeMessages(previous.filter((message) => BigInt(message.id) < oldest), incoming)
}

export function safeUrl(value: unknown): string | null {
  if (typeof value !== "string") return null
  try {
    const url = new URL(value)
    return url.protocol === "https:" && !url.username && !url.password ? url.href : null
  } catch { return null }
}

export function senderName(message: Message, snapshot: ThreadSnapshot): string {
  if (message.out) return "You"
  return message.senderDisplayName?.trim() || snapshot.participants?.find((person) => person.userId === message.fromId)?.displayName.trim()
    || (snapshot.chat.peer?.userId === message.fromId ? snapshot.chat.peer.displayName?.trim() : null) || "Member"
}
