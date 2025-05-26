import { MessageModel, type ProcessedMessage } from "@in/server/db/models/messages"
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
}

const log = new Log("notifications.eval", LogLevel.DEBUG)

let outputSchema = z.object({
  msgId: z.number(),
  mentionedUserIds: z.array(z.number()).nullable(),
  mustSeeUserIds: z.array(z.number()).nullable(),
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
  let model: ChatModel = "gpt-4o-mini" as ChatModel

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
  You are a chat app assistant for Inline Chat app – a work chat app similar to Slack. You are given a new message in a chat and you evaluate who is mentioned and who must be notified immediately.

  # Instructions
  
  - Evaluate which participants are mentioned in messages, put the IDs in the mentioned list. If message is replied to a user, or it's a DM to a user, consider it a mention.
  - Then evaluate which users not only are mentioned or referred to, but additionally must immediately get a special notification because something needs their attention or an incident, event, or an issue has happened that they must be aware of or take action, even if they are asleep. this is NOT for every mention. 
  -  IT IS IMPORTANT TO NOT WAKE UP THE USER UNNECESSARILY. Users enable this when they're alseep. Greetings, links, casual chats, etc should NOT be considered important. Instead bug reports, company issues related to user, important DMs, things that explicitly require their attention etc should be considered important. If a user is mentioned, it's slightly more likely to be important. If someone is asking the user in DM or by mentioning/replying to them to wait or to make sure to look at something or as a follow up of an eariler request, also consider it important to see. Users want to be notified of messages that the sender is waiting for them to see/do or help them.
  - Return user IDs of both groups.
  - Only evaluate messages between <new_messages> tag.

 
  # Examples
<example_context>
particiapants: Amy (user_id: 1), Hassan (user_id: 2), Ellie (user_id: 3)
</example_context>
 <example_message id="0">
hey ellie!
</example_message>
<assistant_response id="0">
[{"msgId": 0, "mentioned": [3], "mustSee": []}]
</assistant_response>
<example_message id="1">
amy can you see the new message, we need it now.
</example_message>
<assistant_response id="1">
[{"msgId": 1, "mentioned": [1], "mustSee": [1]}]
</assistant_response>
<example_message id="4">
Ellie: website is down. @hasan
</example_message>
<assistant_response id="4">
[{"msgId": 4, "mentioned": [2], "mustSee": [2]}]
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
        `<participant userId="${name.id}">${name.firstName ?? ""} ${name.lastName ?? ""} @${
          name.username
        }</participant>`,
    )
    .join("\n")}
  </participants>

  <chat_info>
  ${chatInfo?.title ? `Chat: ${chatInfo?.title}` : ""}
  Chat type: ${chatInfo?.type === "thread" ? "group chat" : "DM"}
  ${spaceInfo ? `Workspace: ${spaceInfo?.name}` : ""}
  ${spaceInfo ? `Workspace description: ${spaceInfo?.name?.includes("Wanver") ? WANVER_TRANSLATION_CONTEXT : ""}` : ""}
  </chat_info>

  <previous_messages>
  ${previousMessages.map(formatMessage).join("\n")}
  </previous_messages>
  `

  return context
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
