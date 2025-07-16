import { MessageEntity_Type, type MessageEntities } from "@in/protocol/core"
import { MessageModel, type ProcessedMessage } from "@in/server/db/models/messages"
import { UserSettingsNotificationsMode, type UserSettingsGeneral } from "@in/server/db/models/userSettings/types"
import type { DbMessage } from "@in/server/db/schema"
import { isProd, WANVER_TRANSLATION_CONTEXT } from "@in/server/env"
import { openaiClient } from "@in/server/libs/openAI"
import { getCachedChatInfo } from "@in/server/modules/cache/chatInfo"
import { getCachedSpaceInfo } from "@in/server/modules/cache/spaceCache"
import { getCachedUserName, UserNamesCache, type UserName } from "@in/server/modules/cache/userNames"
import { filterFalsy } from "@in/server/utils/filter"
import { Log, LogLevel } from "@in/server/utils/log"
import { zodResponseFormat } from "openai/helpers/zod.mjs"
import type { ChatModel } from "openai/resources/chat/chat.mjs"
import z from "zod"

type InputMessage = {
  id: number
  text: string
  entities: MessageEntities | null
  message: DbMessage // or Protocol message?
}

type Input = {
  chatId: number
  // Text content of the message
  message: InputMessage

  participantSettings: {
    userId: number
    settings: UserSettingsGeneral | null
  }[]
}

const log = new Log("notifications.eval")

const DEBUG_AI = !isProd
//const DEBUG_AI = true

let outputSchema = z.object({
  notifyUserIds: z.array(z.number()).nullable(),
  ...(DEBUG_AI ? { reason: z.string().nullable() } : {}),
})

type Output = z.infer<typeof outputSchema>

export type NotificationEvalResult = Output

/** Check if a message should be sent to which users */
export const batchEvaluate = async (_input: Input): Promise<NotificationEvalResult> => {
  let input: Input = {
    ..._input,
    // Don't evaluate filters for the user who sent the message
    participantSettings: _input.participantSettings.filter((p) => p.userId != _input.message.message.fromId),
  }

  const systemPrompt = await getSystemPrompt(input)
  const userPrompt = await getUserPrompt(input)

  if (!openaiClient) {
    throw new Error("OpenAI client not initialized")
  }

  // const model: ChatModel = "gpt-4.1-nano"
  // const model: ChatModel = "gpt-4.1-mini"
  //let model: ChatModel = "gpt-4o-mini" as ChatModel
  let model: ChatModel = "gpt-4.1-mini" as ChatModel

  log.debug(`Notification eval system prompt: ${systemPrompt}`)
  log.debug(`Notification eval user prompt: ${userPrompt}`)

  const response = await openaiClient.chat.completions.create({
    model: model,
    messages: [
      { role: "system", content: systemPrompt },
      { role: "user", content: userPrompt },
    ],
    response_format: zodResponseFormat(outputSchema, "notifications"),
    max_tokens: 16000,
  })

  // // Parse result
  let finishReason = response.choices[0]?.finish_reason
  if (finishReason !== "stop") {
    log.error(`Notification eval failed: ${finishReason}`)
    throw new Error(`Notification eval failed: ${finishReason}`)
  }

  try {
    log.info(`Notification eval result: ${response.choices[0]?.message.content}`)
    log.debug("AI usage", response.usage)

    let inputTokens = response.usage?.prompt_tokens ?? 0
    let outputTokens = response.usage?.completion_tokens ?? 0

    let inputPrice: number
    let outputPrice: number

    if (model === "gpt-4.1-mini") {
      inputPrice = (inputTokens * 0.0004) / 1000
      outputPrice = (outputTokens * 0.0016) / 1000
    } else if (model === "gpt-4.1") {
      inputPrice = (inputTokens * 0.002) / 1000
      outputPrice = (outputTokens * 0.008) / 1000
    } else if (model === "gpt-4.1-nano") {
      inputPrice = (inputTokens * 0.0001) / 1000
      outputPrice = (outputTokens * 0.0004) / 1000
    } else if (model === "gpt-4o-mini") {
      inputPrice = (inputTokens * 0.00015) / 1000
      outputPrice = (outputTokens * 0.0006) / 1000
    } else {
      throw new Error(`Unsupported model: ${model}`)
    }

    let totalPrice = inputPrice + outputPrice

    log.info(`Notification eval price: $${totalPrice.toFixed(4)} • ${model}`)

    const result = outputSchema.parse(JSON.parse(response.choices[0]?.message.content ?? "[]"))

    return result
  } catch (error) {
    log.error(`Notification eval decoding failed: ${error}`)
    throw new Error(`Notification eval decoding failed: ${error}`)
  }
}

const getUserPrompt = async (input: Input): Promise<string> => {
  const usersWithFilters = await Promise.all(
    input.participantSettings.map(async (p) => await formatZenModeRules(p.userId, input)),
  )

  const userPrompt = `
  <new_message>
  ${formatMessage({ ...input.message.message, text: input.message.text, entities: input.message.entities })}
  </new_message>

  According to above message, determine which of the following users should receive a notification:
  
  <users_with_filters>
  ${usersWithFilters.join("\n")}
  </users_with_filters>
  `

  return userPrompt
}

const getSystemPrompt = async (input: Input): Promise<string> => {
  const context = await getContext(input)
  const systemPrompt = `
  # Identity
  You are an assistant for Inline chat app similar to Slack. For a given message, you evaluate who needs to get a notification.

  # Instructions
  - You are given a message and the conversation context
  - Some of participants only want to be notified for messages that pass through a filter they have set. 
  - Determine which users should receive a notification for the given message based on the filters they have set.
  - Return an array of user IDs that should receive a notification. If message doesn't match any of the filters 
  
  # Note
  - @mentions don't necessarily mean the user needs to receive a notification. Users typically use these filters to evaluate if their mentions or direct messages matter to them at the time.
  - Message doesn't need to pass every filter to be notified. If any of the filters match, the user should be notified. 
  ${DEBUG_AI ? `- Return a reason for your evaluation in the reason field.` : ""}

  # Examples 
  - User with ID 1 receives a message from User 2: "hey @user1, watch this cool video" and User 1 has set a filter to receive notifications only if there their servers are down, result is notifyUserIds: []. 
  - User with ID 1 has their filter: "- when John DMs me - there is a bug/incident in production". For a message from User John with ID 2 in a group message chat: "hey @user1, app doesn't work" should result in notifyUserIds: [1].
  - User with ID 1 has their filter: "- all DMs from John". For a message from User John with ID 2 in a direct message chat: "hey" should result in notifyUserIds: [1].
  - User with ID 1 has their filter: "- all messages after 10am my time - only if there is an incident at night". For a message from User John with ID 2 in a group message chat: "hey" should result in notifyUserIds: [1].

  # Context
  ${context}
  `

  return systemPrompt
}

const getContext = async (input: Input): Promise<string> => {
  let chatInfo = await getCachedChatInfo(input.chatId)
  let spaceInfo = chatInfo?.spaceId ? await getCachedSpaceInfo(chatInfo.spaceId) : undefined
  let participantNames = (
    await Promise.all((chatInfo?.participantUserIds ?? []).map((userId) => getCachedUserName(userId)))
  ).filter(filterFalsy)

  let messages = [input.message]
  let previousMessages = await MessageModel.getNonFullMessagesFromNewToOld({
    chatId: input.chatId,
    newestMsgId: Math.min(...messages.map((m) => m.id)),
    limit: 8,
  })

  let date = new Date()

  let rules = await Promise.all(input.participantSettings.map(async (p) => await formatZenModeRules(p.userId, input)))
  let dmParticipants =
    chatInfo?.type === "private"
      ? `direct message chat (DM) between ${await Promise.all(
          chatInfo?.participantUserIds.map(async (userId) => fullDisplayName(await getCachedUserName(userId))) ?? [],
        )}`
      : ""

  let conversation = await Promise.all(previousMessages.map(async (m) => await formatMessageSimple(m)))

  let context = `
  <chat_info>
  ${chatInfo?.title ? `Chat: ${chatInfo?.title}` : ""}
  Chat Type: ${chatInfo?.type === "thread" ? "group chat" : dmParticipants}
  ${spaceInfo ? `Workspace: ${spaceInfo?.name}` : ""}
  ${spaceInfo ? `Description: ${spaceInfo?.name?.includes("Wanver") ? WANVER_TRANSLATION_CONTEXT : ""}` : ""}
  </chat_info>

  <participants>
  ${participantNames
    .map(
      (name) =>
        `<user id="${name.id}" localTime="${
          name.timeZone ? date.toLocaleTimeString("en-US", { timeZone: name.timeZone, timeStyle: "short" }) : "unknown"
        }">
      ${name.firstName ?? ""} ${name.lastName ?? ""} (@${name.username})
      </user>`,
    )
    .join("\n")}
  </participants>

  <conversation>
  ${conversation.join("\n")}
  </conversation>
  `

  return context
}

const formatZenModeRules = async (userId: number, input: Input): Promise<string> => {
  const settings = input.participantSettings.find((p) => p.userId === userId)?.settings?.notifications
  const userName = await getCachedUserName(userId)
  const displayName = userName ? fullDisplayName(userName) : ""

  if (!settings) return ""

  const isZenMode = settings.mode === UserSettingsNotificationsMode.ImportantOnly

  if (!isZenMode) return ""

  let rules = settings.zenModeUsesDefaultRules
    ? `
<filters userId="${userId}">
- An urgent matter has come up (eg. a bug or an incident) or
- Someone is waiting for me to unblock them and I need to come back now/wake up or
- A service, app, website, work tool, etc. is not working well or requires fixing.
</filters>`
    : `
<filters userId="${userId}">
${settings.zenModeCustomRules}
</filters>
  `

  return `Include userId "${userId}" ${
    displayName ? `for ${displayName}` : ""
  } ANY of the following filters: "${rules}"`
}

const fullDisplayName = (userName: UserName | undefined) => {
  if (!userName) return ""

  let displayName = ""
  if (userName.firstName || userName.lastName) {
    displayName += `${userName.firstName ?? ""} ${userName.lastName ?? ""}`
  }
  if (userName.username) {
    displayName += ` (@${userName.username})`
  }

  if (displayName.trim() === "") {
    return `${userName.email}`
  }

  return displayName
}

export const formatMessage = (m: ProcessedMessage): string => {
  return `<message 
id="${m.messageId}"
sentAt="${m.date.toISOString()}"
senderUserId="${m.fromId}" 
${m.replyToMsgId ? `replyToMsgId="${m.replyToMsgId}"` : ""}>
${m.photoId ? "[photo attachment]" : ""} ${m.videoId ? "[video attachment]" : ""} ${
    m.documentId ? "[document attachment]" : ""
  } ${m.text ? m.text : "[empty caption]"}
  ${m.entities ? formatEntities(m.entities) : ""}
  </message>`
}

/** Useful for concise conversation history display */
export const formatMessageSimple = async (m: ProcessedMessage): Promise<string> => {
  let sender = await getCachedUserName(m.fromId)
  let senderDisplayName = sender ? UserNamesCache.getDisplayName(sender) : `User ${m.fromId}`
  let willTruncate = m.text && m.text.length > 200
  let textContent = m.text ? (willTruncate ? m.text.slice(0, 200) + "..." : m.text) : "[empty caption]"
  return `[messageId: ${m.messageId}] ${senderDisplayName} (${relativeTimeFromNow(m.date)}): ${textContent}`
}

export const formatEntities = (entities: MessageEntities): string => {
  let content = entities.entities
    .map(
      (e) =>
        `<entity type="${MessageEntity_Type[e.type]}" offset="${e.offset}" length="${e.length}" ${
          "userId" in e.entity ? `userId="${e.entity.userId}"` : ""
        } />`,
    )
    .join("\n")

  return `<entities>${content}</entities>`
}

/**
 * Returns a relative time label such as:
 *   “just now”, “3 m ago”, “2 h ago”, “5 d ago”, “1 y ago”
 */
export const relativeTimeFromNow = (date: Date): string => {
  const secs = Math.floor((Date.now() - date.getTime()) / 1000)

  const MIN = 60
  const HOUR = 60 * MIN
  const DAY = 24 * HOUR
  const WEEK = 7 * DAY
  const YEAR = 365 * DAY

  switch (true) {
    case secs < 10:
      return "just now"
    case secs < MIN:
      return `${secs}s ago`
    case secs < HOUR:
      return `${Math.floor(secs / MIN)}m ago`
    case secs < DAY:
      return `${Math.floor(secs / HOUR)}h ago`
    case secs < WEEK:
      return `${Math.floor(secs / DAY)}d ago`
    case secs < YEAR:
      return `${Math.floor(secs / WEEK)}w ago`
    default:
      return `${Math.floor(secs / YEAR)}y ago`
  }
}
