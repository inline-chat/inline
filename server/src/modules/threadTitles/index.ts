import { MessageEntity_Type, type MessageEntities } from "@inline-chat/protocol/core"
import type { ChatModel } from "openai/resources/chat/chat.mjs"
import { zodResponseFormat } from "openai/helpers/zod"
import { z } from "zod/v4"
import { db } from "@in/server/db"
import type { DbFullDocument } from "@in/server/db/models/files"
import { MessageModel, type DbFullMessage, type ProcessedMessageAttachment } from "@in/server/db/models/messages"
import { chats, messageAttachments, users, type DbChat, type DbMessage } from "@in/server/db/schema"
import { updateThreadInfo } from "@in/server/functions/messages.updateChatInfo"
import { openaiClient } from "@in/server/libs/openAI"
import { getAnchorMessageForChat, isDefaultReplyThreadTitle } from "@in/server/modules/subthreads"
import { Log } from "@in/server/utils/log"
import { validateIanaTimezone } from "@in/server/utils/validate"
import { eq } from "drizzle-orm"

const log = new Log("modules.threadTitles")

const MIN_SOURCE_CHARS = 12
const MIN_SOURCE_WORDS = 3
const MAX_SOURCE_CHARS = 1600
const MAX_REPLY_SOURCE_CHARS = 2200
const MAX_TITLE_CHARS = 100
const MODEL: ChatModel = "gpt-5.6-luna" as ChatModel

const excludedEntityTypes = new Set<MessageEntity_Type>([
  MessageEntity_Type.MENTION,
  MessageEntity_Type.USERNAME_MENTION,
  MessageEntity_Type.URL,
  MessageEntity_Type.TEXT_URL,
  MessageEntity_Type.EMAIL,
  MessageEntity_Type.PHONE_NUMBER,
  MessageEntity_Type.CODE,
  MessageEntity_Type.PRE,
  MessageEntity_Type.BOT_COMMAND,
])

const titleSchema = z.object({
  title: z.string(),
  emoji: z.string().nullable().optional(),
})

type ThreadTitleChat = Pick<
  DbChat,
  | "id"
  | "type"
  | "title"
  | "description"
  | "isUntitled"
  | "parentChatId"
  | "parentMessageId"
  | "minUserId"
  | "maxUserId"
>
type ThreadTitleMessage = Pick<
  DbMessage,
  | "messageId"
  | "mediaType"
  | "fwdFromPeerUserId"
  | "fwdFromPeerChatId"
  | "fwdFromMessageId"
  | "fwdFromSenderId"
>

export type ThreadTitleAttachmentContext =
  | {
      kind: "urlPreview"
      title?: string | null
      description?: string | null
      author?: string | null
      siteName?: string | null
      fileName?: string | null
    }
  | {
      kind: "externalTask"
      title?: string | null
      application?: string | null
      number?: string | null
    }
  | {
      kind: "document"
      fileName?: string | null
    }

type MaybeScheduleInput = {
  chat: ThreadTitleChat
  message: ThreadTitleMessage
  text: string | undefined
  entities: MessageEntities | undefined
  attachments?: ThreadTitleAttachmentContext[]
  currentUserId: number
}

type GenerateInput = {
  chatId: number
  messageId: number
  text: string
  currentUserId: number
  jobId?: number
}

type GeneratedThreadTitle = {
  title: string
  emoji?: string
}

type ThreadTitleKind = "topLevel" | "reply"

type PreparedGeneration = {
  kind: ThreadTitleKind
  sourceText: string
  titleGuard:
    | { kind: "empty" }
    | { kind: "untitledExact"; currentTitle: string | null }
}

type SourceLine = {
  label: string
  text: string
}

let nextJobId = 0
const pendingJobs = new Map<number, number>()

export function maybeScheduleThreadTitleGeneration(input: MaybeScheduleInput) {
  if (!canAutoTitleThread(input.chat)) {
    return
  }

  const sourceText = getThreadTitleSourceText(input)
  if (!sourceText) {
    return
  }

  cancelPendingThreadTitleGeneration(input.chat.id)

  const jobId = ++nextJobId
  pendingJobs.set(input.chat.id, jobId)

  void generateAndApplyThreadTitle({
    chatId: input.chat.id,
    messageId: input.message.messageId,
    text: sourceText,
    currentUserId: input.currentUserId,
    jobId,
  }).catch((error) => {
    log.warn("Thread title generation failed", {
      chatId: input.chat.id,
      messageId: input.message.messageId,
      error,
    })
  })
}

export function cancelPendingThreadTitleGeneration(chatId: number) {
  pendingJobs.delete(chatId)
}

export async function generateAndApplyThreadTitle(input: GenerateInput): Promise<{ didUpdate: boolean }> {
  try {
    if (input.jobId !== undefined && pendingJobs.get(input.chatId) !== input.jobId) {
      return { didUpdate: false }
    }

    const prepared = await prepareGeneration(input)
    if (!prepared) {
      return { didUpdate: false }
    }

    const generated = await generateThreadTitle(prepared.sourceText, input.currentUserId, prepared.kind)
    if (!generated) {
      return { didUpdate: false }
    }

    if (input.jobId !== undefined && pendingJobs.get(input.chatId) !== input.jobId) {
      return { didUpdate: false }
    }

    const result = await updateThreadInfo({
      chatId: input.chatId,
      title: generated.title,
      emoji: prepared.kind === "topLevel" ? generated.emoji : undefined,
      currentUserId: input.currentUserId,
      titleGuard: prepared.titleGuard,
      isUntitled: true,
    })

    if (result.didUpdate) {
      log.info("Generated thread title", {
        chatId: input.chatId,
        messageId: input.messageId,
      })
    }

    return { didUpdate: result.didUpdate }
  } finally {
    if (input.jobId !== undefined && pendingJobs.get(input.chatId) === input.jobId) {
      pendingJobs.delete(input.chatId)
    }
  }
}

export function canAutoTitleThread(chat: ThreadTitleChat): boolean {
  if (chat.type !== "thread") {
    return false
  }

  if (chat.parentChatId == null) {
    return !isNonEmpty(chat.title)
  }

  return chat.parentMessageId != null && chat.isUntitled === true
}

export async function getMessageAttachmentTitleContext(messageGlobalId: bigint): Promise<ThreadTitleAttachmentContext[]> {
  const attachments = await db._query.messageAttachments.findMany({
    where: eq(messageAttachments.messageId, messageGlobalId),
    with: {
      externalTask: true,
      linkEmbed: true,
    },
  })

  return MessageModel.processAttachments(attachments).flatMap(threadTitleContextFromAttachment)
}

export function threadTitleContextFromAttachment(
  attachment: ProcessedMessageAttachment,
): ThreadTitleAttachmentContext[] {
  const contexts: ThreadTitleAttachmentContext[] = []

  if (attachment.linkEmbed) {
    contexts.push({
      kind: "urlPreview",
      title: attachment.linkEmbed.title,
      description: attachment.linkEmbed.description,
      author: attachment.linkEmbed.author,
      siteName: attachment.linkEmbed.siteName,
      fileName: attachment.linkEmbed.document?.fileName,
    })
  }

  if (attachment.externalTask) {
    contexts.push({
      kind: "externalTask",
      title: attachment.externalTask.title,
      application: attachment.externalTask.application,
      number: attachment.externalTask.number,
    })
  }

  return contexts
}

export function documentTitleContext(
  document: Pick<DbFullDocument, "fileName"> | null | undefined,
): ThreadTitleAttachmentContext[] {
  const fileName = document?.fileName?.trim()
  if (!fileName) {
    return []
  }

  return [{ kind: "document" as const, fileName }]
}

export function getThreadTitleSourceText(input: MaybeScheduleInput): string | undefined {
  if (input.message.mediaType === "nudge" || isForwardedMessage(input.message)) {
    return undefined
  }

  const text = input.text?.trim()
  const messageText = text ? normalizedTitleSource(textWithoutExcludedEntities(text, input.entities)) : ""
  const attachmentLines = attachmentSourceLines(input.attachments)
  const sourceContent = normalizedTitleSource([messageText, ...attachmentLines.map((line) => line.text)].join(" "))
  if (sourceContent.length < MIN_SOURCE_CHARS || wordCount(sourceContent) < MIN_SOURCE_WORDS) {
    return undefined
  }

  const sourceText = formatTitleSource(messageText, attachmentLines)
  return Array.from(sourceText).slice(0, MAX_SOURCE_CHARS).join("")
}

async function prepareGeneration(input: GenerateInput): Promise<PreparedGeneration | undefined> {
  const chat = await db.select().from(chats).where(eq(chats.id, input.chatId)).limit(1).then((rows) => rows[0])
  if (!chat || !canAutoTitleThread(chat)) {
    return undefined
  }

  if (chat.parentMessageId == null) {
    return {
      kind: "topLevel",
      sourceText: input.text,
      titleGuard: { kind: "empty" },
    }
  }

  const anchorMessage = await getAnchorMessageForChat(chat)
  if (!isDefaultReplyThreadTitle(chat.title, anchorMessage)) {
    return undefined
  }

  return {
    kind: "reply",
    sourceText: await buildReplyThreadSource(chat, anchorMessage, input.text, input.currentUserId),
    titleGuard: { kind: "untitledExact", currentTitle: chat.title },
  }
}

async function buildReplyThreadSource(
  chat: ThreadTitleChat,
  anchorMessage: DbFullMessage | undefined,
  firstReplySource: string,
  currentUserId: number,
): Promise<string> {
  const parentChat = chat.parentChatId == null
    ? undefined
    : await db.select().from(chats).where(eq(chats.id, chat.parentChatId)).limit(1).then((rows) => rows[0])
  const parentTitle = parentChat ? await displayParentChatTitle(parentChat, currentUserId) : undefined
  const parentMessageSource = anchorMessage ? messageContextSource(anchorMessage) : undefined
  const lines = [
    "Context type: Reply thread",
    parentTitle ? `Parent chat title: ${contextValue(parentTitle, 200)}` : undefined,
    parentChat?.description ? `Parent chat description: ${contextValue(parentChat.description, 300)}` : undefined,
    anchorMessage ? `Parent message by: ${displayName(anchorMessage.from)}` : undefined,
    parentMessageSource ? `Parent message: ${contextValue(parentMessageSource, 700)}` : undefined,
    `First eligible reply: ${contextValue(firstReplySource, 800)}`,
  ].filter((line): line is string => line !== undefined)

  return Array.from(lines.join("\n")).slice(0, MAX_REPLY_SOURCE_CHARS).join("")
}

async function displayParentChatTitle(chat: DbChat, currentUserId: number): Promise<string> {
  const title = chat.title?.trim()
  if (title) {
    return title
  }

  if (chat.type === "private") {
    const peerUserId = chat.minUserId === currentUserId ? chat.maxUserId : chat.minUserId
    if (peerUserId != null) {
      const peer = await db._query.users.findFirst({ where: eq(users.id, peerUserId) })
      const peerName = peer ? displayName(peer) : undefined
      if (peerName) {
        return `Direct message with ${peerName}`
      }
    }
    return "Direct message"
  }

  return "Untitled thread"
}

function messageContextSource(message: DbFullMessage): string | undefined {
  const text = message.text?.trim()
  const messageText = text ? normalizedTitleSource(textWithoutExcludedEntities(text, message.entities ?? undefined)) : ""
  const attachments = [
    ...documentTitleContext(message.document),
    ...(message.messageAttachments ?? []).flatMap(threadTitleContextFromAttachment),
  ]
  const attachmentLines = attachmentSourceLines(attachments)
  const source = formatTitleSource(messageText, attachmentLines)
  if (source) {
    return source
  }

  if (message.mediaType === "photo") return "Photo"
  if (message.mediaType === "video") return "Video"
  if (message.mediaType === "document") return "Document"
  if (message.mediaType === "voice") return "Voice message"
  if (message.mediaType === "nudge") return "Nudge"
  return undefined
}

async function generateThreadTitle(
  text: string,
  currentUserId: number,
  kind: ThreadTitleKind,
): Promise<GeneratedThreadTitle | undefined> {
  if (!openaiClient) {
    log.debug("Skipping thread title generation because OpenAI client is not initialized")
    return undefined
  }

  const today = formatTodayForThreadTitle(await getUserTimeZone(currentUserId))

  const completion = await openaiClient.chat.completions.parse({
    model: MODEL,
    verbosity: "low",
    reasoning_effort: "none",
    messages: [
      {
        role: "system",
        content: threadTitleSystemPrompt(kind, today),
      },
      {
        role: "user",
        content: text,
      },
    ],
    response_format: zodResponseFormat(titleSchema, "threadTitle"),
  })

  const parsed = completion.choices[0]?.message.parsed
  const title = sanitizeTitle(parsed?.title)
  if (!title) {
    return undefined
  }

  return {
    title,
    emoji: kind === "topLevel" ? sanitizeEmoji(parsed?.emoji) : undefined,
  }
}

function threadTitleSystemPrompt(kind: ThreadTitleKind, today: string): string {
  const shared = `Generate a concise, natural chat thread title from the provided message and attachment context. Default to sentence casing, not title case. If the messages themselves are all lowercase, return the title in lowercase. Prefer 3-6 words. One or two words are good when sufficient, and seven or more are allowed when they materially improve clarity; around six words or fewer is the gold standard, not a hard cap. Today's date is ${today}. For recurring or common things that benefit from date disambiguation, such as meetings, diaries, journals, standups, check-ins, or daily notes, append today's date at the end in parentheses, for example: (${today}). Keep emoji out of the title itself. No quotes.`

  if (kind === "reply") {
    return `${shared} This is a reply thread to the labeled parent message in the labeled parent chat. Name the focused topic of the reply conversation using the parent context and first eligible reply. Do not prefix the title with Re: or Reply. Do not choose an emoji for reply threads; return emoji as null.`
  }

  return `${shared} Optionally return one broadly safe, relevant emoji when it genuinely helps recognition. Keep it tasteful and understated, not formal, cheesy, suggestive, insulting, graphic, political, or religious. Omit it for sensitive, serious, ordinary, or ambiguous topics.`
}

function sanitizeTitle(value: string | undefined): string | undefined {
  const title = value
    ?.replace(/[\p{Extended_Pictographic}\uFE0F\u200D]/gu, "")
    .replace(/\s+/g, " ")
    .replace(/^[`"'“”‘’]+|[`"'“”‘’]+$/g, "")
    .trim()

  if (!title) {
    return undefined
  }

  const clipped = Array.from(title).slice(0, MAX_TITLE_CHARS).join("").trim()
  return clipped.length > 0 ? clipped : undefined
}

function sanitizeEmoji(value: string | null | undefined): string | undefined {
  const emoji = value
    ?.replace(/^[`"'“”‘’]+|[`"'“”‘’]+$/g, "")
    .trim()

  if (!emoji || !isSingleEmoji(emoji)) {
    return undefined
  }

  return emoji
}

async function getUserTimeZone(userId: number): Promise<string | undefined> {
  const user = await db._query.users.findFirst({
    where: eq(users.id, userId),
    columns: { timeZone: true },
  })
  const timeZone = user?.timeZone?.trim()
  return timeZone && validateIanaTimezone(timeZone) ? timeZone : undefined
}

function formatTodayForThreadTitle(timeZone: string | undefined): string {
  const options: Intl.DateTimeFormatOptions = {
    month: "long",
    day: "numeric",
    year: "numeric",
  }
  if (timeZone) {
    options.timeZone = timeZone
  }

  return new Intl.DateTimeFormat("en-US", options).format(new Date())
}

function isSingleEmoji(value: string): boolean {
  return /^(?:\p{Extended_Pictographic}(?:\p{Emoji_Modifier})?(?:\uFE0F|\uFE0E)?(?:\u200D\p{Extended_Pictographic}(?:\p{Emoji_Modifier})?(?:\uFE0F|\uFE0E)?)*|\p{Regional_Indicator}{2}|[#*0-9]\uFE0F?\u20E3)$/u.test(
    value,
  )
}

function displayName(user: Pick<DbFullMessage["from"], "firstName" | "lastName" | "username">): string {
  const fullName = [user.firstName, user.lastName].filter(Boolean).join(" ").trim()
  return fullName || user.username || "Inline member"
}

function contextValue(value: string, maxLength: number): string {
  return Array.from(normalizedTitleSource(value)).slice(0, maxLength).join("")
}

function textWithoutExcludedEntities(text: string, entities: MessageEntities | undefined): string {
  if (!entities || entities.entities.length === 0) {
    return text
  }

  const ranges = entities.entities
    .filter((entity) => excludedEntityTypes.has(entity.type))
    .map((entity) => ({
      start: clampIndex(Number(entity.offset), text.length),
      end: clampIndex(Number(entity.offset + entity.length), text.length),
    }))
    .filter((range) => range.end > range.start)
    .sort((a, b) => a.start - b.start)

  if (ranges.length === 0) {
    return text
  }

  const parts: string[] = []
  let cursor = 0

  for (const range of ranges) {
    if (range.start > cursor) {
      parts.push(text.slice(cursor, range.start))
    }
    cursor = Math.max(cursor, range.end)
  }

  if (cursor < text.length) {
    parts.push(text.slice(cursor))
  }

  return parts.join(" ")
}

function normalizedTitleSource(text: string): string {
  return text
    .replace(/https?:\/\/\S+/gi, " ")
    .replace(/\s+/g, " ")
    .trim()
}

function attachmentSourceLines(attachments: ThreadTitleAttachmentContext[] | undefined): SourceLine[] {
  if (!attachments || attachments.length === 0) {
    return []
  }

  const lines: SourceLine[] = []
  const seen = new Set<string>()

  for (const attachment of attachments) {
    switch (attachment.kind) {
      case "urlPreview":
        appendSourceLine(lines, seen, "URL preview title", attachment.title)
        appendSourceLine(lines, seen, "URL preview description", attachment.description)
        appendSourceLine(lines, seen, "URL preview author", attachment.author)
        appendSourceLine(lines, seen, "URL preview site", attachment.siteName)
        appendSourceLine(lines, seen, "URL preview document", attachment.fileName)
        break
      case "externalTask":
        appendSourceLine(lines, seen, "Task title", attachment.title)
        appendSourceLine(lines, seen, "Task app", attachment.application)
        appendSourceLine(lines, seen, "Task number", attachment.number)
        break
      case "document":
        appendSourceLine(lines, seen, "Document filename", attachment.fileName)
        break
    }
  }

  return lines
}

function appendSourceLine(lines: SourceLine[], seen: Set<string>, label: string, value: string | null | undefined) {
  const text = normalizedTitleSource(value ?? "")
  if (!text) {
    return
  }

  const key = text.toLocaleLowerCase()
  if (seen.has(key)) {
    return
  }

  seen.add(key)
  lines.push({ label, text })
}

function formatTitleSource(messageText: string, attachmentLines: SourceLine[]): string {
  if (attachmentLines.length === 0) {
    return messageText
  }

  const lines = messageText ? [`Message: ${messageText}`] : []
  lines.push(...attachmentLines.map((line) => `${line.label}: ${line.text}`))
  return lines.join("\n")
}

function wordCount(text: string): number {
  return text.match(/[\p{L}\p{N}][\p{L}\p{N}'-]*/gu)?.length ?? 0
}

function clampIndex(value: number, max: number): number {
  if (!Number.isSafeInteger(value)) {
    return 0
  }

  return Math.max(0, Math.min(value, max))
}

function isForwardedMessage(message: ThreadTitleMessage): boolean {
  return (
    message.fwdFromPeerUserId != null ||
    message.fwdFromPeerChatId != null ||
    message.fwdFromMessageId != null ||
    message.fwdFromSenderId != null
  )
}

function isNonEmpty(value: string | null): boolean {
  return value != null && value.trim().length > 0
}
