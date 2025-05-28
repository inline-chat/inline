import type { NotificationSettings, UserSettings } from "@in/protocol/core"
import { MessageModel, type ProcessedMessage } from "@in/server/db/models/messages"
import { UserSettingsNotificationsMode, type UserSettingsGeneral } from "@in/server/db/models/userSettings/types"
import type { DbMessage } from "@in/server/db/schema"
import { WANVER_TRANSLATION_CONTEXT } from "@in/server/env"
import { openaiClient } from "@in/server/libs/openAI"
import { getCachedChatInfo } from "@in/server/modules/cache/chatInfo"
import { getCachedSpaceInfo } from "@in/server/modules/cache/spaceCache"
import { getCachedUserName } from "@in/server/modules/cache/userNames"
import { filterFalsy } from "@in/server/utils/filter"
import { Log, LogLevel } from "@in/server/utils/log"
import { zodResponseFormat } from "openai/helpers/zod.mjs"
import type { ChatModel } from "openai/resources/chat/chat.mjs"
import z from "zod"

type InputMessage = {
  id: number
  text: string
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

const log = new Log("notifications.eval", LogLevel.INFO)

let outputSchema = z.object({
  msgId: z.number(),
  mentionedUserIds: z.array(z.number()).nullable(),
  notifyUserIds: z.array(z.number()).nullable(),
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
    log.debug(`Notification eval result: ${response.choices[0]?.message.content}`)
    // log.debug(`Notification eval system prompt: ${systemPrompt}`)
    // log.debug(`Notification eval user prompt: ${userPrompt}`)
    log.debug("AI usage", response.usage)

    let inputTokens = response.usage?.prompt_tokens ?? 0
    let outputTokens = response.usage?.completion_tokens ?? 0

    let inputPrice: number
    let outputPrice: number

    if (model === "gpt-4.1-mini") {
      inputPrice = (inputTokens * 0.0004) / 1000
      outputPrice = (outputTokens * 0.0016) / 1000
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
  let messages = [input.message]
  const userPrompt = `
  <new_messages>
  ${messages.map((m) => formatMessage({ ...m.message, text: m.text })).join("\n")}
  </new_messages>
  `

  return userPrompt
}

const getSystemPrompt = async (input: Input): Promise<string> => {
  const context = await getContext(input)
  const systemPrompt = `
  # Identity
  You are a chat app notification assistant for Inline Chat app – a work chat app similar to Slack. You are given a new message in a chat and you evaluate who is mentioned and who needs to be notified based on a set of rules for each user.

  # Instructions
  
  - Evaluate which participants are mentioned in a message. Mentioning means @username or their first name appearing in the message. 
  - If message is a reply to the user, or it's a DM from someone to the user, consider it a mention for that user ID.
  - For the next step, you are given a set of rules for each user ID to use as a criteria to determine if the user needs to be notified. Users set these rules so they can focus or sleep without being distracted by messages that aren't important to that user.
  - If the message matches the criteria user has set, include the user ID in the notifyUserIds array. 
  - Use the chat context, previous messages and meaning of messages to infer if the new message matches what user wants to be notified for more broadly. eg. if user is set to notify when something urgent has came up, and the message is about a bug or an incident, include the user ID in the notifyUserIds array even if the word "urgent" or "bug" is not in the message. The user is describing a situation, not a literal pattern matching.
  - Return user IDs of both groups.

  # Examples
<example_context>
particiapants: Amy (user_id: 1), Hassan (user_id: 2), Ellie (user_id: 3)
settings for user ids 1,2,3: notify when something urgent has came up (eg. a bug or an incident). 
</example_context>
 <example id="0">
hey Ellie!
</example>
<assistant_response id="0">
[{"msgId": 0, "mentionedUserIds": [3], "notifyUserIds": []}]
</assistant_response>
<example id="1">
amy can you see the new message, we need it now.
</example>
<assistant_response id="1">
[{"msgId": 1, "mentionedUserIds": [1], "notifyUserIds": [1]}]
</assistant_response>
<example id="4">
Ellie: website is down. @hasan
</example>
<assistant_response id="4">
[{"msgId": 4, "mentionedUserIds": [2], "notifyUserIds": [2]}]
</assistant_response>
<example id="5" chat_type="DM with Hassan">
Ellie: hey
</example>
<assistant_response id="5">
[{"msgId": 5, "mentionedUserIds": [2], "notifyUserIds": []}]
</assistant_response>
</examples>


  # Context
  <context>
  ${context}
  </context>
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
    limit: 10,
  })

  // get previous messages

  let context = `
  <participants>
  ${participantNames
    .map(
      (name) =>
        `<participant userId="${name.id}">
      Name: ${name.firstName ?? ""} ${name.lastName ?? ""} 
      Username: @${name.username}
      Notifications: ${formatNotificationSettings(name.id, input)}
      </participant>`,
    )
    .join("\n")}
  </participants>

  <chat_info>
  ${chatInfo?.title ? `Chat: ${chatInfo?.title}` : ""}
  Chat type: ${chatInfo?.type === "thread" ? "group chat" : `DM between ${chatInfo?.participantUserIds.join(", ")}`}
  ${spaceInfo ? `Workspace: ${spaceInfo?.name}` : ""}
  ${spaceInfo ? `Workspace description: ${spaceInfo?.name?.includes("Wanver") ? WANVER_TRANSLATION_CONTEXT : ""}` : ""}
  </chat_info>

  <previous_messages>
  ${previousMessages.map(formatMessage).join("\n")}
  </previous_messages>
  `

  return context
}

const formatNotificationSettings = (userId: number, input: Input): string => {
  const settings = input.participantSettings.find((p) => p.userId === userId)?.settings?.notifications

  if (!settings) return "No settings"

  const isZenMode = settings.mode === UserSettingsNotificationsMode.ImportantOnly
  const isMentionMode = settings.mode === UserSettingsNotificationsMode.Mentions
  const requiresMention = settings.zenModeRequiresMention

  let rules = settings.zenModeUsesDefaultRules
    ? `
  <rules>
${requiresMention ? "Only if mentioned or replied to in a message, AND rules below apply:" : ""}
- Something urgent has came up (eg. a bug or an incident). 
- I must wake up for something, I must handle something.
- Someone is desperatly waiting for me to unblock them and cannot wait anymore.
  </rules>`
    : `<rules>
${requiresMention ? "Only if mentioned or replied to in a message, AND rules below apply:" : ""}
${settings.zenModeCustomRules}
</rules>
  `

  return `
  Notify ${userId} for: ${isMentionMode ? "Mentions" : isZenMode ? "Messages that match the criteria" : "None"}
  ${isZenMode ? `User ${userId} wants to be notified when: "${rules}"` : ""}
  `
}

export const formatMessage = (m: ProcessedMessage): string => {
  return `<message 
id="${m.messageId}"
sentAt="${m.date.toISOString()}"
senderId="${m.fromId}" 
${m.replyToMsgId ? `replyToId="${m.replyToMsgId}"` : ""}>
${m.photoId ? "[photo attachment]" : ""} ${m.videoId ? "[video attachment]" : ""} ${
    m.documentId ? "[document attachment]" : ""
  } ${m.text ? m.text : "[empty caption]"}</message>`
}

// # Examples
// <example_context>
// particiapants: Amy (user_id: 1), Hassan (user_id: 2), Ellie (user_id: 3)
// </example_context>
//  <example id="0">
// hey ellie!
// </example>
// <assistant_response id="0">
// [{"msgId": 0, "mentioned": [3], "mustSee": []}]
// </assistant_response>
// <example id="1">
// amy can you see the new message, we need it now.
// </example>
// <assistant_response id="1">
// [{"msgId": 1, "mentioned": [1], "mustSee": [1]}]
// </assistant_response>
// <example id="4">
// Ellie: website is down. @hasan
// </example>
// <assistant_response id="4">
// [{"msgId": 4, "mentioned": [2], "mustSee": [2]}]
// </assistant_response>
// <example id="6">
// Amy: Are you there? One sec, sending you a code, can you read it? (replying to Ellie)
// </example>
// <assistant_response id="6">
// [{"msgId": 6, "mentioned": [3], "mustSee": [3]}]
// </assistant_response>
// <example id="7">
// Hassan: Amy are you awake? wake up please
// </example>
// <assistant_response id="7">
// [{"msgId": 7, "mentioned": [1], "mustSee": [1]}]
// </assistant_response>
// </examples>
