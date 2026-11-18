/**
 * Compose activity (typing, uploading, recording), after the Mac's
 * `ComposeActions.swift`. Ephemeral: nothing here touches the replica.
 *
 * Outgoing (`composeAction` intents):
 * - `typing` is sent at most once per `refreshMs` (3 s); the UI reports it
 *   on keystrokes, and the remote side expires it on its own.
 * - Other actions (uploads, recording, agent work) are sent at once and
 *   refreshed every `refreshMs` until stopped or replaced. Typing does not
 *   replace them.
 * - `null` stops: a stop is sent only if something was sent.
 * - Sends are best effort (`transient`): offline they are dropped.
 *
 * Incoming (`updateComposeAction` pushes): each user's action per chat,
 * expiring `expireMs` (6 s) after its last refresh; `NONE` removes it, and a
 * new message from that user in that chat ends it (except agent work).
 */
import {
  UpdateComposeAction_ComposeAction as Action,
  type Peer,
  type Update,
} from "@inline-chat/protocol/core"
import {
  COMPOSE_ACTION_RULE,
  type ComposeActionKind,
  type ComposeActivity,
} from "@inline/core-protocol"
import { chatId as makeChatId, userId as makeUserId, type ChatID, type UserID } from "@inline/ids"

const toProtocol: Record<ComposeActionKind, Action> = {
  typing: Action.TYPING,
  uploadingPhoto: Action.UPLOADING_PHOTO,
  uploadingDocument: Action.UPLOADING_DOCUMENT,
  uploadingVideo: Action.UPLOADING_VIDEO,
  recordingVoice: Action.RECORDING_VOICE,
  working: Action.WORKING,
}

const fromProtocol = (action: Action): ComposeActionKind | undefined =>
  (Object.entries(toProtocol) as [ComposeActionKind, Action][]).find(([, value]) => value === action)?.[0]

export type ComposeOptions = {
  userId: UserID
  /** Send one action (undefined: stop). Best effort; failures are ignored. */
  send: (chatId: ChatID, action: Action | undefined) => Promise<unknown>
  /** The chat of a direct-message peer user, from the replica. */
  chatForUser: (userId: UserID) => ChatID | undefined
  now: () => number
  /** Incoming activity changed for this chat. */
  onChange: (chatId: ChatID) => void
}

type Outgoing = { action?: ComposeActionKind; lastSent?: number; sent: boolean; timer?: ReturnType<typeof setInterval> }

type Incoming = ComposeActivity & { timer: ReturnType<typeof setTimeout> }

export class ComposeActivityStore {
  private readonly outgoing = new Map<ChatID, Outgoing>()
  private readonly incoming = new Map<string, Incoming>()
  private stopped = false

  constructor(private readonly options: ComposeOptions) {}

  // ---- Outgoing ----------------------------------------------------------

  set(chatId: ChatID, action: ComposeActionKind | null) {
    if (this.stopped) return
    const state = this.outgoing.get(chatId) ?? { sent: false }
    this.outgoing.set(chatId, state)
    if (action === null) {
      if (state.timer) clearInterval(state.timer)
      this.outgoing.delete(chatId)
      if (state.sent) this.transmit(chatId, undefined)
      return
    }
    if (action === "typing") {
      // An upload or recording already speaks for this chat.
      if (state.action && state.action !== "typing") return
      state.action = "typing"
      const now = this.options.now()
      if (state.lastSent != null && now - state.lastSent < COMPOSE_ACTION_RULE.refreshMs) return
      state.lastSent = now
      state.sent = true
      this.transmit(chatId, Action.TYPING)
      return
    }
    if (state.action === action && state.timer) return
    if (state.timer) clearInterval(state.timer)
    state.action = action
    state.lastSent = this.options.now()
    state.sent = true
    this.transmit(chatId, toProtocol[action])
    state.timer = setInterval(() => {
      state.lastSent = this.options.now()
      this.transmit(chatId, toProtocol[action])
    }, COMPOSE_ACTION_RULE.refreshMs)
  }

  private transmit(chatId: ChatID, action: Action | undefined) {
    void this.options.send(chatId, action).catch(() => undefined)
  }

  // ---- Incoming ----------------------------------------------------------

  activities(chatId?: ChatID): ComposeActivity[] {
    const list: ComposeActivity[] = []
    for (const entry of this.incoming.values()) {
      if (chatId && entry.chatId !== chatId) continue
      list.push({ chatId: entry.chatId, userId: entry.userId, action: entry.action })
    }
    return list.sort((left, right) =>
      left.chatId === right.chatId ? compare(left.userId, right.userId) : compare(left.chatId, right.chatId),
    )
  }

  /** Updates delivered by a push or a catch-up page (never stored). */
  observe(updates: readonly Update[]) {
    if (this.stopped) return
    for (const update of updates) {
      const body = update.update
      if (body.oneofKind === "updateComposeAction") {
        const userId = makeUserId(body.updateComposeAction.userId)
        if (userId === this.options.userId) continue
        const chatId = this.chatOf(body.updateComposeAction.peerId, userId)
        if (!chatId) continue
        const action = fromProtocol(body.updateComposeAction.action)
        if (action) this.add(chatId, userId, action)
        else this.remove(chatId, userId)
      } else if (body.oneofKind === "newMessage") {
        const message = body.newMessage.message
        if (!message) continue
        const userId = makeUserId(message.fromId)
        const chatId = makeChatId(message.chatId)
        const entry = this.incoming.get(`${chatId}:${userId}`)
        if (entry && entry.action !== "working") this.remove(chatId, userId)
      }
    }
  }

  private chatOf(peer: Peer | undefined, sender: UserID): ChatID | undefined {
    const type = peer?.type
    if (type?.oneofKind === "chat") return makeChatId(type.chat.chatId)
    if (type?.oneofKind === "user") {
      // In a direct chat the peer is the other side: the sender, as seen from here.
      const other = makeUserId(type.user.userId)
      return this.options.chatForUser(other === this.options.userId ? sender : other)
    }
    return undefined
  }

  private add(chatId: ChatID, userId: UserID, action: ComposeActionKind) {
    const key = `${chatId}:${userId}`
    const previous = this.incoming.get(key)
    if (previous) clearTimeout(previous.timer)
    const timer = setTimeout(() => this.remove(chatId, userId), COMPOSE_ACTION_RULE.expireMs)
    this.incoming.set(key, { chatId, userId, action, timer })
    if (previous?.action !== action) this.options.onChange(chatId)
  }

  private remove(chatId: ChatID, userId: UserID) {
    const key = `${chatId}:${userId}`
    const entry = this.incoming.get(key)
    if (!entry) return
    clearTimeout(entry.timer)
    this.incoming.delete(key)
    this.options.onChange(chatId)
  }

  /** Connection lost: incoming activity is no longer known. */
  clearIncoming() {
    const chats = new Set(Array.from(this.incoming.values(), (entry) => entry.chatId))
    for (const entry of this.incoming.values()) clearTimeout(entry.timer)
    this.incoming.clear()
    for (const chatId of chats) this.options.onChange(chatId)
  }

  stop() {
    this.stopped = true
    for (const state of this.outgoing.values()) if (state.timer) clearInterval(state.timer)
    this.outgoing.clear()
    for (const entry of this.incoming.values()) clearTimeout(entry.timer)
    this.incoming.clear()
  }
}

const compare = (left: string, right: string) => {
  const a = BigInt(left)
  const b = BigInt(right)
  return a < b ? -1 : a > b ? 1 : 0
}
