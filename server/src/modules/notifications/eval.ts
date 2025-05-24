import { MessageModel, type ProcessedMessage } from "@in/server/db/models/messages"
import type { DbMessage } from "@in/server/db/schema"
import { WANVER_TRANSLATION_CONTEXT } from "@in/server/env"
import { openaiClient } from "@in/server/libs/openAI"
import { getCachedChatInfo } from "@in/server/modules/cache/chatInfo"
import { getCachedSpaceInfo } from "@in/server/modules/cache/spaceCache"
import { getCachedUserName } from "@in/server/modules/cache/userNames"
import { filterFalsy } from "@in/server/utils/filter"
import { Log } from "@in/server/utils/log"
import { zodResponseFormat } from "openai/helpers/zod.mjs"
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

const log = new Log("notifications.eval")

let outputSchema = z.object({
  msgId: z.number(),
  mentionedUserIds: z.array(z.number()),
  mustSeeUserIds: z.array(z.number()),
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

  const response = await openaiClient.chat.completions.create({
    //model: "gpt-4.1-nano",
    // 4o mini?
    model: "gpt-4.1-mini",
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
    log.debug(`Notification eval system prompt: ${systemPrompt}`)
    log.debug(`Notification eval user prompt: ${userPrompt}`)
    log.debug("AI usage", response.usage)

    // Calculate price based on token usage for 4.1-nano model
    // Input tokens: $0.1 per 1M tokens ($0.00010 per 1K tokens)
    // Output tokens: $0.4 per 1M tokens ($0.0004 per 1K tokens)
    const inputTokens = response.usage?.prompt_tokens ?? 0
    const outputTokens = response.usage?.completion_tokens ?? 0

    // 4.1-mini
    const inputPrice = (inputTokens * 0.0004) / 1000
    const outputPrice = (outputTokens * 0.0016) / 1000

    // 4.1-nano
    // const inputPrice = (inputTokens * 0.0001) / 1000
    // const outputPrice = (outputTokens * 0.0004) / 1000
    const totalPrice = inputPrice + outputPrice

    log.info(`Notification eval price: $${totalPrice.toFixed(4)} `)

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
  
  - Evaluate which of the participants are mentioned in the messages, put the IDs in the mentioned list.
  - Then evaluate which users not only are mentioned or referred to, but additionally must immediately get a loud sound notification because something urgent needs their attention or an incident, significant event, or an issue has happened that they must be aware of or take action, even if they are asleep. This mode is ONLY for important messages, NOT for every mention. 
  - DO NOT return user IDs of users who are mentioned but not important in the mustSee list. IT IS IMPORTANT TO NOT WAKE UP THE USER UNNECESSARILY. Users enable this when they're alseep. Greetings, links, casual chats, etc should NOT be considered important. 
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
<example_message id="2">
Hassan (replied to message 1): I need a response now.
</example_message>
<assistant_response id="2">
[{"msgId": 2, "mentioned": [], "mustSee": [1]}]
</assistant_response>
<example_message id="3">
Amy: I think Ben and Ellie are invited, yeah.
</example_message>
<assistant_response id="3">
[{"msgId": 2, "mentioned": [3], "mustSee": []}]
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
  ${chatInfo?.title ? `Chat title: ${chatInfo?.title}` : ""}
  Chat type: ${chatInfo?.type === "thread" ? "group chat" : "DM"}
  ${spaceInfo ? `Workspace name: ${spaceInfo?.name}` : ""}
  ${spaceInfo ? `Workspace description: ${spaceInfo?.name?.includes("Wanver") ? WANVER_TRANSLATION_CONTEXT : ""}` : ""}
  </chat_info>

  <previous_messages>
  ${previousMessages.map(formatMessage).join("\n")}
  </previous_messages>
  `

  return context
}

const formatMessage = (m: ProcessedMessage): string => {
  return `<message 
id="${m.messageId}"
sentAt="${m.date.toISOString()}"
senderId="${m.fromId}" 
${m.replyToMsgId ? `replyToId="${m.replyToMsgId}"` : ""}>
${m.photoId ? "[photo attachment]" : ""} ${m.videoId ? "[video attachment]" : ""} ${
    m.documentId ? "[document attachment]" : ""
  } ${m.text ? m.text : "[empty text]"}</message>`
}
