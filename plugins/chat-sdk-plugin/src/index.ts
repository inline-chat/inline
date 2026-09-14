import { timingSafeEqual } from "node:crypto"
import { InlineBotClient } from "@inline-chat/bot-client"
import type {
  BotApiEnvelope,
  BotMessage,
  BotUser,
  BotUpdate,
  BotTargetInput,
  BotFile,
} from "@inline-chat/bot-api-types"
import {
  Message,
  NotImplementedError,
  RateLimitError,
  defaultEmojiResolver,
  stringifyMarkdown,
  type Adapter,
  type AdapterPostableMessage,
  type Author,
  type ChatInstance,
  type EmojiValue,
  type FetchOptions,
  type FormattedContent,
  type WebhookOptions,
  type Attachment,
} from "chat"

import { messageToFormatted } from "./markdown.js"
export { messageToMarkdown } from "./markdown.js"
import { isInlineUpdate } from "./updates.js"
import { renderContent } from "./content.js"

export interface InlineAdapterConfig {
  token: string
  /** Must match setWebhook.secret_token. Required; unauthenticated webhooks are never accepted. */
  webhookSecret: string
  baseUrl?: string
  fetch?: typeof fetch
}

export type InlineThreadId = { kind: "chat" | "user"; id: string }

export class InlineApiError extends Error {
  constructor(readonly code: number, readonly description: string) {
    super(`Inline Bot API (${code}): ${description}`)
    this.name = "InlineApiError"
  }
}

function result<T>(response: BotApiEnvelope<T>): T {
  if (response.ok) return response.result
  if (response.error_code === 429) {
    throw new RateLimitError(
      response.description,
      response.parameters?.retry_after === undefined ? undefined : response.parameters.retry_after * 1000,
    )
  }
  throw new InlineApiError(response.error_code, response.description)
}

function id(value: string): string {
  if (!/^[1-9]\d*$/.test(value) || BigInt(value) > 4_503_599_627_370_495n) {
    throw new Error("Invalid Inline ID")
  }
  return value
}

/** Each Inline conversation, including a native reply thread, has its own Chat SDK thread. */
export class InlineAdapter implements Adapter<InlineThreadId, BotMessage> {
  readonly name = "inline"
  readonly lockScope = "thread" as const
  readonly client: InlineBotClient
  userName = "inline-bot"
  botUserId?: string
  private chat?: ChatInstance
  private readonly secret: Buffer
  private readonly fetchImpl: typeof fetch

  constructor(config: InlineAdapterConfig) {
    if (!config.token.trim()) throw new Error("Inline bot token is required")
    if (!config.webhookSecret || Buffer.byteLength(config.webhookSecret) > 256) {
      throw new Error("Inline webhook secret must contain 1–256 bytes")
    }
    this.secret = Buffer.from(config.webhookSecret)
    this.fetchImpl = config.fetch ?? fetch
    this.client = new InlineBotClient({
      token: config.token,
      ...(config.baseUrl ? { baseUrl: config.baseUrl } : {}),
      ...(config.fetch ? { fetch: config.fetch } : {}),
    })
  }

  async initialize(chat: ChatInstance): Promise<void> {
    const { user } = result(await this.client.getMe())
    this.botUserId = String(user.id)
    this.userName = user.username ?? chat.getUserName()
    this.chat = chat
  }

  encodeThreadId(thread: InlineThreadId): string {
    if (thread.kind !== "chat" && thread.kind !== "user") throw new Error("Invalid Inline peer kind")
    return `inline:${thread.kind}:${id(thread.id)}`
  }

  decodeThreadId(threadId: string): InlineThreadId {
    const match = /^inline:(chat|user):([1-9]\d*)$/.exec(threadId)
    if (!match) throw new Error("Invalid Inline thread ID")
    return { kind: match[1] as "chat" | "user", id: id(match[2]!) }
  }

  private messageId(threadId: string, nativeId: number): string {
    return `${threadId}:${nativeId}`
  }

  private nativeMessageId(threadId: string, messageId: string): string {
    if (!messageId.startsWith(`${threadId}:`)) throw new Error("Inline message belongs to a different conversation")
    return id(messageId.slice(threadId.length + 1))
  }

  private target(threadId: string): BotTargetInput {
    const peer = this.decodeThreadId(threadId)
    return peer.kind === "user" ? { user_id: peer.id } : { chat_id: peer.id }
  }

  private threadId(raw: BotMessage): string {
    return raw.peer_id.user_id !== undefined
      ? this.encodeThreadId({ kind: "user", id: String(raw.peer_id.user_id) })
      : this.encodeThreadId({ kind: "chat", id: String(raw.peer_id.chat_id) })
  }

  channelIdFromThreadId(threadId: string): string {
    this.decodeThreadId(threadId)
    return threadId
  }

  isDM(threadId: string): boolean {
    return this.decodeThreadId(threadId).kind === "user"
  }
  async openDM(userId: string): Promise<string> {
    return this.encodeThreadId({ kind: "user", id: userId })
  }

  private author(user: BotUser): Author {
    return {
      userId: String(user.id),
      userName: user.username ?? String(user.id),
      fullName: [user.first_name, user.last_name].filter(Boolean).join(" ") || user.username || String(user.id),
      isBot: user.is_bot,
      isMe: String(user.id) === this.botUserId,
    }
  }

  parseMessage(raw: BotMessage): Message<BotMessage> {
    const text = raw.text ?? ""
    return new Message({
      id: this.messageId(this.threadId(raw), raw.message_id),
      threadId: this.threadId(raw),
      text,
      raw,
      formatted: messageToFormatted(raw),
      author: this.author(raw.from),
      isMention:
        raw.entities?.some((entity) => entity.type === "text_mention" && String(entity.user?.id) === this.botUserId) ??
        false,
      metadata: {
        dateSent: new Date(raw.date * 1000),
        edited: raw.edit_date !== undefined,
        ...(raw.edit_date !== undefined ? { editedAt: new Date(raw.edit_date * 1000) } : {}),
      },
      ...(raw.reply_to_message ? { replyTo: this.parseMessage(raw.reply_to_message) } : {}),
      attachments: this.messageAttachments(raw),
    })
  }

  renderFormatted(content: FormattedContent): string {
    return stringifyMarkdown(content)
  }

  private messageAttachments(raw: BotMessage): Attachment[] {
    const attachments: Attachment[] = []
    const append = (file: BotFile, kind: string) => attachments.push(this.attachment(
      file, kind === "photo" ? "image" : kind === "voice" ? "audio" : kind === "video" ? "video" : "file",
    ))
    if (raw.media && "file" in raw.media) append(raw.media.file, raw.media.type)
    return attachments
  }

  private attachment(file: BotFile, type: Attachment["type"]): Attachment {
    return this.rehydrateAttachment({
      type,
      name: file.file_name,
      mimeType: file.mime_type,
      size: file.file_size,
      width: file.width,
      height: file.height,
      fetchMetadata: { fileId: file.file_id },
    })
  }

  rehydrateAttachment(attachment: Attachment): Attachment {
    const fileId = attachment.fetchMetadata?.fileId
    if (!fileId) return attachment
    return {
      ...attachment,
      fetchData: async () => {
        const { file } = result(await this.client.getFile({ file_id: fileId }))
        if (!file.download_url) throw new Error("Inline did not return a file download URL")
        // Refresh the signed URL on each download; never attach the bot authorization header.
        const response = await this.fetchImpl(file.download_url)
        if (!response.ok) throw new Error(`Inline file download failed (${response.status})`)
        return response.arrayBuffer()
      },
    }
  }

  private async content(message: AdapterPostableMessage) {
    const content = renderContent(message)
    const files = typeof message === "string" || !("files" in message) ? [] : message.files ?? []
    if (files.length > 1) throw new NotImplementedError("Inline adapter 0.1 supports one file per message")
    if (files.length === 0) return { ...content, media: undefined }
    const media = []
    for (const upload of files) {
      const blob = upload.data instanceof Blob ? upload.data : new Blob(
        [new Uint8Array(upload.data instanceof ArrayBuffer ? upload.data : Uint8Array.from(upload.data).buffer)],
        { type: upload.mimeType },
      )
      const type = "document" as const
      const { file } = result(await this.client.uploadFile({ type, file: blob, file_name: upload.filename }))
      media.push({ type, file_id: file.file_id })
    }
    return { ...content, media: media[0]! }
  }

  async postMessage(threadId: string, message: AdapterPostableMessage) {
    const { message: raw } = result(
      await this.client.sendMessage({ ...this.target(threadId), ...(await this.content(message)) }),
    )
    return { id: this.messageId(threadId, raw.message_id), threadId, raw }
  }

  async reply(threadId: string, messageId: string, message: AdapterPostableMessage) {
    const replyId = this.nativeMessageId(threadId, messageId)
    const { message: raw } = result(
      await this.client.sendMessage({
        ...this.target(threadId),
        ...(await this.content(message)),
        reply_to_message_id: replyId,
      }),
    )
    return { id: this.messageId(threadId, raw.message_id), threadId, raw }
  }

  async postChannelMessage(channelId: string, message: AdapterPostableMessage) {
    return this.postMessage(channelId, message)
  }

  async editMessage(threadId: string, messageId: string, message: AdapterPostableMessage) {
    if (typeof message !== "string" && "files" in message && message.files?.length) {
      throw new NotImplementedError("Inline adapter 0.1 does not support replacing message attachments")
    }
    const content = await this.content(message)
    const target = { ...this.target(threadId), message_id: this.nativeMessageId(threadId, messageId) }
    const { message: raw } = result(await this.client.editMessageText({ ...target, actions: [], ...content }))
    return { id: this.messageId(threadId, raw.message_id), threadId, raw }
  }

  async deleteMessage(threadId: string, messageId: string): Promise<void> {
    result(
      await this.client.deleteMessage({
        ...this.target(threadId),
        message_id: this.nativeMessageId(threadId, messageId),
      }),
    )
  }

  async addReaction(threadId: string, messageId: string, emoji: EmojiValue | string): Promise<void> {
    result(
      await this.client.sendReaction({
        ...this.target(threadId),
        message_id: this.nativeMessageId(threadId, messageId),
        emoji: defaultEmojiResolver.toGChat(emoji),
      }),
    )
  }

  async removeReaction(threadId: string, messageId: string, emoji: EmojiValue | string): Promise<void> {
    result(
      await this.client.deleteReaction({
        ...this.target(threadId),
        message_id: this.nativeMessageId(threadId, messageId),
        emoji: defaultEmojiResolver.toGChat(emoji),
      }),
    )
  }

  async startTyping(threadId: string): Promise<void> {
    result(await this.client.sendChatAction({ ...this.target(threadId), action: "typing" }))
  }

  async endTyping(threadId: string): Promise<void> {
    result(await this.client.sendChatAction({ ...this.target(threadId), action: "cancel" }))
  }

  async fetchMessage(threadId: string, messageId: string) {
    const { messages } = result(
      await this.client.getMessages({
        ...this.target(threadId),
        message_ids: [this.nativeMessageId(threadId, messageId)],
      }),
    )
    return messages[0] ? this.parseMessage(messages[0]) : null
  }

  async fetchMessages(threadId: string, options: FetchOptions = {}) {
    if (options.direction === "forward")
      throw new NotImplementedError("Inline Bot API supports backward history pagination only")
    const limit = options.limit ?? 50
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new Error("Inline history limit must be 1–100")
    const { messages } = result(
      await this.client.getChatHistory({
        ...this.target(threadId),
        limit,
        ...(options.cursor ? { offset_message_id: id(options.cursor) } : {}),
      }),
    )
    const sorted = [...messages].sort((a, b) => a.message_id - b.message_id)
    return {
      messages: sorted.map((message) => this.parseMessage(message)),
      ...(messages.length === limit && sorted[0] ? { nextCursor: String(sorted[0].message_id) } : {}),
    }
  }

  async fetchChannelMessages(channelId: string, options?: FetchOptions) {
    return this.fetchMessages(channelId, options)
  }

  async fetchChannelInfo(channelId: string) {
    const { chat } = result(await this.client.getChat(this.target(channelId)))
    return {
      id: channelId,
      name: chat.title,
      isDM: this.isDM(channelId),
      memberCount: chat.participants?.count,
      metadata: { chat },
    }
  }

  async fetchThread(threadId: string) {
    const { chat } = result(await this.client.getChat(this.target(threadId)))
    return { id: threadId, channelId: threadId, channelName: chat.title, isDM: this.isDM(threadId), metadata: { chat } }
  }

  async handleWebhook(request: Request, options?: WebhookOptions): Promise<Response> {
    if (request.method !== "POST") return new Response("Method not allowed", { status: 405 })
    const supplied = Buffer.from(request.headers.get("x-inline-bot-api-secret-token") ?? "")
    if (supplied.length !== this.secret.length || !timingSafeEqual(supplied, this.secret)) {
      return new Response("Unauthorized", { status: 401 })
    }
    if (!this.chat) throw new Error("Inline adapter has not been initialized")
    let update: BotUpdate
    try {
      const payload: unknown = await request.json()
      if (!isInlineUpdate(payload)) return new Response("Invalid update", { status: 400 })
      update = payload
    } catch {
      return new Response("Invalid JSON", { status: 400 })
    }
    const work = this.dispatch(update)
    if (options?.waitUntil) options.waitUntil(work)
    else await work
    return new Response("OK")
  }

  private async dispatch(update: BotUpdate): Promise<void> {
    const chat = this.chat!
    if ("message" in update || "edited_message" in update) {
      const raw = "message" in update ? update.message : update.edited_message
      const message = this.parseMessage(raw)
      if (message.author.isMe) return
      message.isMention = message.isMention || update.activation_reason === "mention"
      if ("edited_message" in update) {
        await chat.processMessageUpdated({ adapter: this, threadId: message.threadId, message })
      } else {
        const text = raw.text ?? ""
        const match = /^\/([a-zA-Z0-9_]+)(?:@([a-zA-Z0-9_]+))?(?=\s|$)/.exec(text)
        const recognized =
          update.activation_reason === "command" ||
          raw.entities?.some((entity) => entity.type === "bot_command" && entity.offset === 0)
        if (recognized && match) {
          if (match[2] && match[2].toLowerCase() !== this.userName.toLowerCase()) return
          const key = `inline:${this.botUserId}:command:${message.id}`
          if (!(await chat.getState().setIfNotExists(key, true, 7 * 24 * 60 * 60 * 1000))) return
          const tasks: Promise<unknown>[] = []
          try {
            chat.processSlashCommand(
              {
                adapter: this,
                channelId: message.threadId,
                command: `/${match[1]}`,
                text: text.slice(match[0].length).trimStart(),
                user: message.author,
                raw: update,
              },
              {
                waitUntil: (task) => {
                  tasks.push(task)
                },
              },
            )
            await Promise.all(tasks)
          } catch (error) {
            await chat.getState().delete(key)
            throw error
          }
        } else await chat.processMessage(this, message.threadId, message)
      }
      return
    }
    if (!("message_action" in update) && !("message_reaction" in update)) return
    const event = "message_action" in update ? update.message_action : update.message_reaction
    if (String(event.actor.id) === this.botUserId) return
    // A DM event's human actor is the peer; group events use the conversation ID.
    const threadId = this.encodeThreadId({
      kind: event.chat.type === "user" ? "user" : "chat",
      id: String(event.chat.type === "user" ? event.actor.id : event.chat.chat_id),
    })
    const messageId = this.messageId(threadId, event.message_id)
    const key = `inline:${this.botUserId}:update:${update.update_id}`
    if (!(await chat.getState().setIfNotExists(key, true, 7 * 24 * 60 * 60 * 1000))) return
    try {
      if ("message_action" in update) {
        const action = update.message_action
        result(await this.client.answerMessageAction({ interaction_id: action.interaction_id }))
        await chat.processAction(
          {
            adapter: this,
            threadId,
            messageId,
            user: this.author(event.actor),
            actionId: action.action.action_id,
            value: action.action.callback_data ?? action.action.callback_data_base64,
            raw: update,
          },
          undefined,
        )
      } else if ("message_reaction" in update) {
        const reaction = update.message_reaction
        const old = new Set(reaction.old_reaction.map((item) => item.emoji))
        const next = new Set(reaction.new_reaction.map((item) => item.emoji))
        const tasks: Promise<unknown>[] = []
        for (const [values, previous, added] of [
          [next, old, true],
          [old, next, false],
        ] as const) {
          for (const rawEmoji of values) {
            if (!previous.has(rawEmoji))
              chat.processReaction(
                {
                  adapter: this,
                  threadId,
                  messageId,
                  emoji: defaultEmojiResolver.fromGChat(rawEmoji),
                  rawEmoji,
                  added,
                  user: this.author(event.actor),
                  raw: update,
                },
                {
                  waitUntil: (task) => {
                    tasks.push(task)
                  },
                },
              )
          }
        }
        await Promise.all(tasks)
      }
    } catch (error) {
      await chat.getState().delete(key)
      throw error
    }
  }
}

export function createInlineAdapter(config: InlineAdapterConfig): InlineAdapter {
  return new InlineAdapter(config)
}
