import { MessageEntity_Type, type MessageEntities } from "@inline-chat/protocol/core"
import type { ChatModel } from "openai/resources/chat/chat.mjs"
import { zodResponseFormat } from "openai/helpers/zod"
import { z } from "zod/v4"
import type { DbChat, DbMessage } from "@in/server/db/schema"
import { updateThreadInfo } from "@in/server/functions/messages.updateChatInfo"
import { openaiClient } from "@in/server/libs/openAI"
import { Log } from "@in/server/utils/log"

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

type MaybeScheduleInput = {
  chat: ThreadTitleChat
  message: ThreadTitleMessage
  text: string | undefined
  entities: MessageEntities | undefined
  currentUserId: number
}

type GenerateInput = {
  chatId: number
  messageId: number
  text: string
  currentUserId: number
  jobId?: number
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

    const title = await generateThreadTitle(input.text)
    if (!title) {
      return { didUpdate: false }
    }

    if (input.jobId !== undefined && pendingJobs.get(input.chatId) !== input.jobId) {
      return { didUpdate: false }
    }

    const result = await updateThreadInfo({
      chatId: input.chatId,
      title,
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

export function getThreadTitleSourceText(input: MaybeScheduleInput): string | undefined {
  if (input.message.mediaType === "nudge" || isForwardedMessage(input.message)) {
    return undefined
  }

  const text = input.text?.trim()
  if (!text) {
    return undefined
  }

  const sourceText = normalizedTitleSource(textWithoutExcludedEntities(text, input.entities))
  if (sourceText.length < MIN_SOURCE_CHARS || wordCount(sourceText) < MIN_SOURCE_WORDS) {
    return undefined
  }

  return Array.from(sourceText).slice(0, MAX_SOURCE_CHARS).join("")
}

async function generateThreadTitle(text: string): Promise<string | undefined> {
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
          "Generate a concise, plain chat thread title from the first substantial message. No emoji. No quotes. Prefer 3-7 words. Return only the structured title.",
      },
      {
        role: "user",
        content: text,
      },
    ],
    response_format: zodResponseFormat(titleSchema, "threadTitle"),
  })

  const title = completion.choices[0]?.message.parsed?.title
  return sanitizeTitle(title)
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
