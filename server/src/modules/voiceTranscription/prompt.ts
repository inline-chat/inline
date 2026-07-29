import type { DbFullVoice } from "@in/server/db/models/files"
import { MessageModel } from "@in/server/db/models/messages"
import type { DbMessage } from "@in/server/db/schema"
import { getCachedChatInfo } from "@in/server/modules/cache/chatInfo"
import { getCachedSpaceInfo } from "@in/server/modules/cache/spaceCache"
import { getCachedUserName, type UserName } from "@in/server/modules/cache/userNames"

const maxParticipantNames = 24
const maxNameLength = 80
const maxTitleLength = 140
const maxKeywordCount = 64
const maxKeywordLength = 80
const recentMessageScanLimit = 32
const maxRecentTranscripts = 4
const maxRecentTranscriptLength = 240
const commonKeywords = [
  "Inline",
  "RealtimeV2",
  "OpenClaw",
  "iOS",
  "macOS",
  "API",
  "PR",
  "DM",
  "work chat",
  "direct message",
]

export type VoiceTranscriptionContextInput = {
  message: DbMessage
  voice: DbFullVoice
}

export type VoiceTranscriptionContext = {
  prompt: string
  keywords: string[]
  languages: string[]
  chatType?: "private" | "thread"
  participantCount: number
  includedParticipantCount: number
  recentTranscriptCount: number
  hasChatTitle: boolean
  hasSpaceName: boolean
}

export function baseVoiceTranscriptionContext(): VoiceTranscriptionContext {
  return buildVoiceTranscriptionContextFromParts({})
}

export type VoiceTranscriptionContextParts = {
  chatType?: "private" | "thread"
  chatTitle?: string
  spaceName?: string
  senderName?: string
  participantKeywords?: string[]
  participantCount?: number
  includedParticipantCount?: number
  recentTranscripts?: string[]
  voiceDurationSeconds?: number | null
}

export function buildVoiceTranscriptionContextFromParts(
  parts: VoiceTranscriptionContextParts,
): VoiceTranscriptionContext {
  const chatTitle = cleanText(parts.chatTitle, maxTitleLength)
  const spaceName = cleanText(parts.spaceName, maxTitleLength)
  const senderName = cleanText(parts.senderName, maxNameLength * 2)
  const recentTranscripts = (parts.recentTranscripts ?? [])
    .map((transcript) => cleanText(transcript, maxRecentTranscriptLength))
    .filter((transcript): transcript is string => Boolean(transcript))
    .slice(-maxRecentTranscripts)
  const keywords = uniqueKeywords([
    chatTitle,
    spaceName,
    ...(parts.participantKeywords ?? []),
    ...commonKeywords,
  ]).slice(0, maxKeywordCount)

  return {
    prompt: buildPromptText({
      chatType: parts.chatType,
      chatTitle,
      spaceName,
      senderName,
      recentTranscripts,
      voiceDurationSeconds: parts.voiceDurationSeconds,
    }),
    keywords,
    // TODO: Populate from user.languages once the product user model exposes it.
    languages: [],
    chatType: parts.chatType,
    participantCount: parts.participantCount ?? 0,
    includedParticipantCount: parts.includedParticipantCount ?? 0,
    recentTranscriptCount: recentTranscripts.length,
    hasChatTitle: Boolean(chatTitle),
    hasSpaceName: Boolean(spaceName),
  }
}

export async function buildVoiceTranscriptionContext(
  input: VoiceTranscriptionContextInput,
): Promise<VoiceTranscriptionContext> {
  const chatInfo = await getCachedChatInfo(input.message.chatId)
  const spaceInfo = chatInfo?.spaceId ? await getCachedSpaceInfo(chatInfo.spaceId) : undefined
  const senderName = await userLabel(input.message.fromId)
  const participantIds = uniqueIds([input.message.fromId, ...(chatInfo?.participantUserIds ?? [])])
  const includedParticipantIds = participantIds.slice(0, maxParticipantNames)
  const participantKeywords = await participantKeywordHints(includedParticipantIds)
  const recentTranscripts = await recentVoiceTranscripts(input.message)

  return buildVoiceTranscriptionContextFromParts({
    chatType: chatInfo?.type,
    chatTitle: chatInfo?.title ?? undefined,
    spaceName: spaceInfo?.name ?? undefined,
    senderName,
    participantKeywords,
    participantCount: participantIds.length,
    includedParticipantCount: includedParticipantIds.length,
    recentTranscripts,
    voiceDurationSeconds: input.voice.duration ?? undefined,
  })
}

function buildPromptText({
  chatType,
  chatTitle,
  spaceName,
  senderName,
  recentTranscripts,
  voiceDurationSeconds,
}: {
  chatType?: "private" | "thread"
  chatTitle?: string
  spaceName?: string
  senderName?: string
  recentTranscripts?: string[]
  voiceDurationSeconds?: number | null
}): string {
  return [
    "A voice message recorded in Inline, a work chat app for teammates.",
    "- Message kind: voice message",
    chatType ? `- Chat type: ${chatType === "private" ? "direct message" : "thread"}` : undefined,
    chatTitle ? `- Chat title: ${chatTitle}` : undefined,
    spaceName ? `- Space/workspace: ${spaceName}` : undefined,
    senderName ? `- Voice sender: ${senderName}` : undefined,
    voiceDurationSeconds !== undefined && voiceDurationSeconds !== null
      ? `- Voice duration: ${voiceDurationSeconds} seconds`
      : undefined,
    recentTranscripts?.length ? "Earlier voice-message transcripts in this chat, oldest to newest:" : undefined,
    ...(recentTranscripts?.map((transcript, index) => `${index + 1}. ${transcript}`) ?? []),
  ]
    .filter((line): line is string => Boolean(line))
    .join("\n")
}

async function participantKeywordHints(userIds: number[]): Promise<string[]> {
  const keywords = await Promise.all(userIds.map((userId) => userNameKeywords(userId)))
  return uniqueKeywords(keywords.flat())
}

async function userNameKeywords(userId: number): Promise<string[]> {
  const name = await getCachedUserName(userId)
  if (!name) return []

  return [
    [name.firstName, name.lastName].filter(Boolean).join(" "),
    name.username,
  ].filter((keyword): keyword is string => Boolean(keyword))
}

async function userLabel(userId: number): Promise<string | undefined> {
  const name = await getCachedUserName(userId)
  return userNameLabel(name) ?? `User ${userId}`
}

function userNameLabel(name: UserName | undefined): string | undefined {
  if (!name) return undefined

  const fullName = cleanText([name.firstName, name.lastName].filter(Boolean).join(" "), maxNameLength)
  const username = cleanText(name.username ? `@${name.username}` : undefined, maxNameLength)

  if (fullName && username) return `${fullName} (${username})`
  return fullName ?? username
}

function uniqueIds(ids: number[]): number[] {
  return Array.from(new Set(ids.filter((id) => Number.isInteger(id) && id > 0)))
}

function uniqueKeywords(values: Array<string | null | undefined>): string[] {
  const seen = new Set<string>()
  const result: string[] = []

  for (const value of values) {
    const keyword = cleanKeyword(value)
    if (!keyword) continue
    const key = keyword.toLowerCase()
    if (seen.has(key)) continue
    seen.add(key)
    result.push(keyword)
  }

  return result
}

async function recentVoiceTranscripts(message: DbMessage): Promise<string[]> {
  const recentMessages = await MessageModel.getNonFullMessagesFromNewToOld({
    chatId: message.chatId,
    newestMsgId: message.messageId,
    limit: recentMessageScanLimit,
  })

  return recentMessages
    .filter((candidate) => candidate.mediaType === "voice")
    .map((candidate) => cleanText(candidate.text, maxRecentTranscriptLength))
    .filter((transcript): transcript is string => Boolean(transcript))
    .slice(-maxRecentTranscripts)
}

function cleanKeyword(value: string | null | undefined): string | undefined {
  return cleanText(value?.replace(/[<>\r\n]/g, " "), maxKeywordLength)
}

function cleanText(value: string | null | undefined, maxLength: number): string | undefined {
  const cleaned = value?.replace(/\s+/g, " ").trim()
  if (!cleaned) return undefined
  return cleaned.length > maxLength ? `${cleaned.slice(0, maxLength).trim()}...` : cleaned
}
