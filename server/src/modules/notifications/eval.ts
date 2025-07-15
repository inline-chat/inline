import { MessageEntity_Type, type MessageEntities } from "@in/protocol/core"
import { MessageModel, type ProcessedMessage } from "@in/server/db/models/messages"
import { UserSettingsNotificationsMode, type UserSettingsGeneral } from "@in/server/db/models/userSettings/types"
import type { DbMessage } from "@in/server/db/schema"
import { isProd, WANVER_TRANSLATION_CONTEXT } from "@in/server/env"
import { openaiClient } from "@in/server/libs/openAI"
import { getCachedChatInfo } from "@in/server/modules/cache/chatInfo"
import { getCachedSpaceInfo } from "@in/server/modules/cache/spaceCache"
import { getCachedUserName, type UserName } from "@in/server/modules/cache/userNames"
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

const log = new Log("notifications.eval", LogLevel.DEBUG)

//const DEBUG_AI = !isProd
const DEBUG_AI = true

let outputSchema = z.object({
  notifyUserIds: z.array(z.number()).nullable(),
  ...(DEBUG_AI ? { reason: z.string().nullable() } : {}),
})

type Output = z.infer<typeof outputSchema>

export type NotificationEvalResult = Output

/** Check if a message should be sent to which users */
export const batchEvaluate = async (input: Input): Promise<NotificationEvalResult> => {
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
      outputPrice = (outputTokens * 0.08) / 1000
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
  const userPrompt = `
  ${formatMessage({ ...input.message.message, text: input.message.text, entities: input.message.entities })}
  `

  return userPrompt
}

const getSystemPrompt = async (input: Input): Promise<string> => {
  const context = await getContext(input)
  const systemPrompt = `
  # Identity
  You are an assistant for Inline – a chat app similar to Slack. You are given a message and you must evaluate who needs to get a notification on their phones based on a set of filters that each user has set. 

  # Instructions

  - You are given a message that mentions a user or a few users. 
  - Analyse the message, previous messages, participants, and the context of where chat is happening
  - Some of participants have enabled a set of notification filters with custom rules to limit what they want to get notification for. They use it when sleeping at night or when they're in focus to avoid waking up for messages they don't want to be notified for. For example is user A receives a message: "hey @userA, watch this cool video" and User A has set a rule to notify them only if there is an incident, then this message should not be notified to user A.
  - Even if the message is a direct mention, but doesn't follow user's filters, you should not trigger the notification for that user. People mention/DM/reply frequently but not all of them should wake up the user. Unless they ask for a broad filter (eg. all DMs from a specific user, all messages, all mentions, etc. in that case respect the user's ask)
  - For each user, if the message matches any of the filters they have set, include their user ID in the notifyUserIds array. 
  - For example, user A (ID: 1) says: "notify me when John DMs me, or there is a bug/incident in production". In this case you should check if message is from John, or message is in another chat and matches the criteria (is about an website incident) and if it matches include user ID "1" in the result array. 
  - IMPORTANT: Be accurate and careful in your evaluation otherwise users may lose important messages which they wanted to get a notification for. Consider all the filters.
  - If user lists multiple filters, if ANY of their filters match, you should trigger the notification for the user who asked to be notified. Even if some of the filters don't match.
  - to trigger the notification for a user, you include the user ID in the notifyUserIds array.
  - If message contains only a few @ mentions, there is a high chance these users need to take action and should be notified. consider the previous messages for the context of evaluation.
  - If it doesn't concern any of the users, return an empty array.
  ${DEBUG_AI ? `- Return a reason for your evaluation in the reason field.` : ""}

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

  let context = `
  <participants>
  ${participantNames
    .map(
      (name) =>
        `<user userId="${name.id}" localTime="${
          name.timeZone ? date.toLocaleTimeString("en-US", { timeZone: name.timeZone }) : ""
        }">
      ${name.firstName ?? ""} ${name.lastName ?? ""} (@${name.username})
      </user>`,
    )
    .join("\n")}
  </participants>

  <chat_info>
  ${chatInfo?.title ? `Chat: ${chatInfo?.title}` : ""}
  Chat Type: ${chatInfo?.type === "thread" ? "group chat" : dmParticipants}
  ${spaceInfo ? `Workspace: ${spaceInfo?.name}` : ""}
  ${spaceInfo ? `Description: ${spaceInfo?.name?.includes("Wanver") ? WANVER_TRANSLATION_CONTEXT : ""}` : ""}
  </chat_info>

  <user_rules>
  ${rules.join("\n")}
  </user_rules>

  <messages>
  ${previousMessages.map(formatMessage).join("\n")}
  </messages>
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
<filter userId="${userId}">
- An urgent matter has come up (eg. a bug or an incident) or
- Someone is waiting for me to unblock them and I need to come back now/wake up or
- A service, app, website, work tool, etc. is not working well or requires fixing.
</filter>`
    : `
<filter userId="${userId}">
${settings.zenModeCustomRules}
or any of the following:
- An urgent matter has come up or
- Someone is depending on me to unblock them in an important matter and I need to come back now/wake up.
</filter>
  `

  return `Include userId "${userId}" ${
    displayName ? `for ${displayName}` : ""
  } in the result if the message passes any of the filters they have set: "${rules}"`
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
