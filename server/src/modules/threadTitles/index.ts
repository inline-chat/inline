import { MessageEntity_Type, type MessageEntities } from "@inline-chat/protocol/core"
import type { ChatModel } from "openai/resources/chat/chat.mjs"
import { zodResponseFormat } from "openai/helpers/zod"
import { z } from "zod/v4"
import { db } from "@in/server/db"
import type { DbFullDocument } from "@in/server/db/models/files"
import { MessageModel, type ProcessedMessageAttachment } from "@in/server/db/models/messages"
import { messageAttachments, type DbChat, type DbMessage } from "@in/server/db/schema"
import { updateThreadInfo } from "@in/server/functions/messages.updateChatInfo"
import { openaiClient } from "@in/server/libs/openAI"
import { Log } from "@in/server/utils/log"
import { eq } from "drizzle-orm"

const log = new Log("modules.threadTitles")

const MIN_SOURCE_CHARS = 12
const MIN_SOURCE_WORDS = 3
const MAX_SOURCE_CHARS = 1600
const MAX_TITLE_CHARS = 70
const MODEL: ChatModel = "gpt-5.4-mini" as ChatModel

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

type ThreadTitleChat = Pick<DbChat, "id" | "type" | "title" | "parentChatId">
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

  cancelPendingThreadTitleGeneration(input.chat.id)

  const sourceText = getThreadTitleSourceText(input)
  if (!sourceText) {
    return
  }

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

    const generated = await generateThreadTitle(input.text)
    if (!generated) {
      return { didUpdate: false }
    }

    if (input.jobId !== undefined && pendingJobs.get(input.chatId) !== input.jobId) {
      return { didUpdate: false }
    }

    const result = await updateThreadInfo({
      chatId: input.chatId,
      title: generated.title,
      emoji: generated.emoji,
      currentUserId: input.currentUserId,
      onlyIfTitleEmpty: true,
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
  return chat.type === "thread" && chat.parentChatId == null && !isNonEmpty(chat.title)
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

async function generateThreadTitle(text: string): Promise<GeneratedThreadTitle | undefined> {
  if (!openaiClient) {
    log.debug("Skipping thread title generation because OpenAI client is not initialized")
    return undefined
  }

  const completion = await openaiClient.chat.completions.parse({
    model: MODEL,
    verbosity: "low",
    reasoning_effort: "low",
    messages: [
      {
        role: "system",
        content:
          "Generate a concise, plain chat thread title from the first substantial message and attachment context. Keep emoji out of the title. Optionally return one emoji only when it strongly matches the topic or intent; omit it for ordinary or ambiguous cases, roughly half of the time. No quotes. Prefer 3-7 title words.",
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
    emoji: sanitizeEmoji(parsed?.emoji),
  }
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

function isSingleEmoji(value: string): boolean {
  return /^(?:\p{Extended_Pictographic}(?:\p{Emoji_Modifier})?(?:\uFE0F|\uFE0E)?(?:\u200D\p{Extended_Pictographic}(?:\p{Emoji_Modifier})?(?:\uFE0F|\uFE0E)?)*|\p{Regional_Indicator}{2}|[#*0-9]\uFE0F?\u20E3)$/u.test(
    value,
  )
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
