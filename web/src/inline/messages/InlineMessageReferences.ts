import {
  DbObjectKind,
  getMessageReferences,
  messageModel,
  messageKey,
  type Db,
  type Message,
  type RealtimeService,
} from "@inline/client/core"
import type { InputPeer } from "@inline-chat/protocol/core"
import type { ChatID, MessageID } from "@inline/ids"

export type InlineMessageReferenceRequest = {
  peerId: InputPeer
  chatId: ChatID
  messageIds: MessageID[]
}

export type InlineMessageReferenceLoader = (
  request: InlineMessageReferenceRequest,
) => Promise<Message[]>

export interface InlineMessageReferencesService {
  load(request: InlineMessageReferenceRequest): Promise<Message[]>
  peek(chatId: ChatID, messageId: MessageID): Message | undefined
  subscribe(listener: () => void): () => void
  getSnapshot(): number
}

const MAX_RESIDENT_REFERENCES = 500

/** A bounded, renderer-safe side cache. It never joins Db's history query. */
export class InlineMessageReferences
  implements InlineMessageReferencesService
{
  private readonly objects = new Map<string, Message>()
  private readonly pending = new Map<string, Promise<Message[]>>()
  private readonly listeners = new Set<() => void>()
  private revision = 0

  constructor(private readonly loader: InlineMessageReferenceLoader) {}

  peek(chatId: ChatID, messageId: MessageID) {
    return this.objects.get(messageKey(chatId, messageId))
  }

  subscribe = (listener: () => void) => {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  getSnapshot = () => this.revision

  async load(request: InlineMessageReferenceRequest) {
    const uniqueIds = Array.from(new Set(request.messageIds))
    const missing = uniqueIds.filter(
      (id) => !this.objects.has(messageKey(request.chatId, id)),
    )
    if (missing.length === 0) {
      return uniqueIds.flatMap((id) => {
        const object = this.peek(request.chatId, id)
        return object ? [object] : []
      })
    }

    const key = `${request.chatId}:${missing.slice().sort().join(",")}`
    let operation = this.pending.get(key)
    if (!operation) {
      operation = this.loader({ ...request, messageIds: missing })
      this.pending.set(key, operation)
    }
    try {
      const loaded = await operation
      if (loaded.length > 0) {
        for (const object of loaded) {
          this.objects.delete(object.id)
          this.objects.set(object.id, object)
        }
        while (this.objects.size > MAX_RESIDENT_REFERENCES) {
          const oldest = this.objects.keys().next().value
          if (oldest == null) break
          this.objects.delete(oldest)
        }
        this.revision += 1
        for (const listener of this.listeners) listener()
      }
    } finally {
      this.pending.delete(key)
    }

    return uniqueIds.flatMap((id) => {
      const object = this.peek(request.chatId, id)
      return object ? [object] : []
    })
  }
}

export const createOwnedMessageReferenceLoader = (
  db: Db,
  realtime: RealtimeService,
): InlineMessageReferenceLoader =>
  async ({ peerId, chatId, messageIds }) => {
    const keys = messageIds.map((id) => messageKey(chatId, id))
    const stored = await db.readStoredObjects(
      DbObjectKind.Message,
      keys,
    )
    const foundIds = new Set(stored.map((message) => message.messageId))
    const missing = messageIds.filter((id) => !foundIds.has(id))
    if (missing.length === 0 || realtime.connectionState !== "connected") {
      return stored
    }

    const result = await realtime.query(
      getMessageReferences({ peerId, messageIds: missing }),
    )
    const remote =
      result?.oneofKind === "getMessages"
        ? result.getMessages.messages.map(messageModel)
        : []
    const merged = new Map(stored.map((message) => [message.id, message]))
    for (const message of remote) merged.set(message.id, message)
    return messageIds.flatMap((id) => {
      const message = merged.get(messageKey(chatId, id))
      return message ? [message] : []
    })
  }
