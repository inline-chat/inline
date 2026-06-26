import type { DbFullVoice } from "@in/server/db/models/files"
import type { DbMessage } from "@in/server/db/schema"
import { getCachedChatInfo } from "@in/server/modules/cache/chatInfo"
import { getCachedSpaceInfo } from "@in/server/modules/cache/spaceCache"
import { getCachedUserName, type UserName } from "@in/server/modules/cache/userNames"

const maxParticipantNames = 24
const maxNameLength = 80
const maxTitleLength = 140

export type VoiceTranscriptionPromptInput = {
  message: DbMessage
  voice: DbFullVoice
}

export type VoiceTranscriptionPrompt = {
  prompt: string
  chatType?: "private" | "thread"
  participantCount: number
  includedParticipantCount: number
  hasChatTitle: boolean
  hasSpaceName: boolean
}

export function baseVoiceTranscriptionPrompt(): VoiceTranscriptionPrompt {
  return {
    prompt: buildPromptText({}),
    participantCount: 0,
    includedParticipantCount: 0,
    hasChatTitle: false,
    hasSpaceName: false,
  }
}

export async function buildVoiceTranscriptionPrompt(
  input: VoiceTranscriptionPromptInput,
): Promise<VoiceTranscriptionPrompt> {
  const chatInfo = await getCachedChatInfo(input.message.chatId)
  const spaceInfo = chatInfo?.spaceId ? await getCachedSpaceInfo(chatInfo.spaceId) : undefined
  const senderName = await userLabel(input.message.fromId)
  const participantIds = uniqueIds([input.message.fromId, ...(chatInfo?.participantUserIds ?? [])])
  const includedParticipantIds = participantIds.slice(0, maxParticipantNames)
  const participantNames = await participantNameHints(includedParticipantIds)
  const chatTitle = cleanText(chatInfo?.title, maxTitleLength)
  const spaceName = cleanText(spaceInfo?.name, maxTitleLength)

  return {
    prompt: buildPromptText({
      chatType: chatInfo?.type,
      chatTitle,
      spaceName,
      senderName,
      participantNames,
      omittedParticipantCount: Math.max(0, participantIds.length - includedParticipantIds.length),
      voiceDurationSeconds: input.voice.duration ?? undefined,
    }),
    chatType: chatInfo?.type,
    participantCount: participantIds.length,
    includedParticipantCount: participantNames.length,
    hasChatTitle: Boolean(chatTitle),
    hasSpaceName: Boolean(spaceName),
  }
}

function buildPromptText({
  chatType,
  chatTitle,
  spaceName,
  senderName,
  participantNames,
  omittedParticipantCount,
  voiceDurationSeconds,
}: {
  chatType?: "private" | "thread"
  chatTitle?: string
  spaceName?: string
  senderName?: string
  participantNames?: string[]
  omittedParticipantCount?: number
  voiceDurationSeconds?: number | null
}): string {
  const participantLine = participantNames?.length
    ? `${participantNames.join(", ")}${omittedParticipantCount ? `, and ${omittedParticipantCount} more` : ""}`
    : undefined

  return [
    "You are transcribing a voice message in Inline, a work chat app for teammates.",
    "Return only the spoken words as the transcript. Do not summarize, translate, answer, add commentary, or add speaker labels unless they were spoken.",
    "Use the context below only to spell names, projects, teams, product terms, and acronyms correctly. Do not include this context unless it was actually spoken.",
    "If the audio is unclear, transcribe the best supported words and do not invent names or facts.",
    "",
    "Context:",
    "- Message kind: voice message",
    chatType ? `- Chat type: ${chatType === "private" ? "direct message" : "thread"}` : undefined,
    chatTitle ? `- Chat title: ${chatTitle}` : undefined,
    spaceName ? `- Space/workspace: ${spaceName}` : undefined,
    senderName ? `- Voice sender: ${senderName}` : undefined,
    participantLine ? `- Participant/name hints: ${participantLine}` : undefined,
    voiceDurationSeconds !== undefined && voiceDurationSeconds !== null
      ? `- Voice duration: ${voiceDurationSeconds} seconds`
      : undefined,
    "- Common Inline/work terms: Inline, work chat, space, thread, direct message, DM, teammate, PR, API, server, client, iOS, macOS, RealtimeV2, OpenClaw.",
  ]
    .filter((line): line is string => Boolean(line))
    .join("\n")
}

async function participantNameHints(userIds: number[]): Promise<string[]> {
  const labels = await Promise.all(userIds.map((userId) => userNameHint(userId)))
  return uniqueLabels(labels.filter((label): label is string => Boolean(label)))
}

async function userNameHint(userId: number): Promise<string | undefined> {
  const name = await getCachedUserName(userId)
  return userNameLabel(name)
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

function uniqueLabels(labels: string[]): string[] {
  const seen = new Set<string>()
  const result: string[] = []

  for (const label of labels) {
    const key = label.toLowerCase()
    if (seen.has(key)) continue
    seen.add(key)
    result.push(label)
  }

  return result
}

function cleanText(value: string | null | undefined, maxLength: number): string | undefined {
  const cleaned = value?.replace(/\s+/g, " ").trim()
  if (!cleaned) return undefined
  return cleaned.length > maxLength ? `${cleaned.slice(0, maxLength).trim()}...` : cleaned
}
