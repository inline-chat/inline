import { openaiClient } from "@in/server/libs/openAI"
import {
  getActiveDatabaseData,
  getNotionUsers,
  newNotionPage,
  getSampleDatabasePages,
  getNotionClient,
  formatNotionUsers,
  type NotionUser,
} from "./notion"
import { MessageModel, type ProcessedMessage } from "@in/server/db/models/messages"
import { Log, LogLevel } from "@in/server/utils/log"
import { WANVER_TRANSLATION_CONTEXT } from "@in/server/env"
import { getCachedChatInfo, type CachedChatInfo } from "@in/server/modules/cache/chatInfo"
import { getCachedSpaceInfo } from "@in/server/modules/cache/spaceCache"
import { getCachedUserName, type UserName } from "@in/server/modules/cache/userNames"
import { filterFalsy } from "@in/server/utils/filter"
import { zodResponseFormat } from "openai/helpers/zod.mjs"
import {
  generateNotionPropertiesSchema,
  findTitleProperty,
  extractTaskTitle,
  getPropertyDescriptions,
} from "./schemaGenerator"
import { formatMessage } from "@in/server/modules/notifications/eval"

const log = new Log("NotionAgent", LogLevel.INFO)

async function createNotionPage(input: { spaceId: number; chatId: number; messageId: number; currentUserId: number }) {
  if (!openaiClient) {
    throw new Error("OpenAI client not initialized")
  }

  // First, get the Notion client and database info
  const { client, databaseId } = await getNotionClient(input.spaceId)

  if (!databaseId) {
    Log.shared.error("No databaseId found", { spaceId: input.spaceId })
    throw new Error("No databaseId found")
  }

  // Run all data fetching operations in parallel - this is the biggest optimization
  const [notionUsers, database, samplePages, targetMessage, messages, chatInfo, participantNames] = await Promise.all([
    getNotionUsers(input.spaceId, client).then(formatNotionUsers),
    getActiveDatabaseData(input.spaceId, databaseId, client),
    getSampleDatabasePages(input.spaceId, databaseId, 4, client),
    MessageModel.getMessage(input.messageId, input.chatId),
    MessageModel.getMessagesAroundTarget(input.chatId, input.messageId, 10, 10),
    getCachedChatInfo(input.chatId),
    // Fetch participant names in parallel instead of sequentially
    getCachedChatInfo(input.chatId).then(async (chatInfo) => {
      if (!chatInfo?.participantUserIds) return []
      const names = await Promise.all(chatInfo.participantUserIds.map((userId) => getCachedUserName(userId)))
      return names.filter(filterFalsy)
    }),
  ])

  console.log("🌴🌴🌴🌴 notionUsers", notionUsers)
  console.log("🌴🌴🌴🌴 database", database)
  console.log("🌴🌴🌴🌴 samplePages", samplePages)

  log.info("Creating Notion page", { database: database?.id, chatTitle: chatInfo?.title, chatId: input.chatId })

  if (!database) {
    throw new Error("No active database found")
  }

  if (!chatInfo) {
    throw new Error("Could not find chat information in database")
  }

  let userPrompt = taskPrompt(
    notionUsers,
    database,
    samplePages,
    messages,
    targetMessage,
    chatInfo,
    participantNames,
    input.currentUserId,
  )

  const completion = await openaiClient.chat.completions.create({
    model: "gpt-4.1",

    messages: [
      {
        role: "system",
        content: systemPrompt,
      },
      {
        role: "user",
        content: userPrompt,
      },
    ],
    response_format: zodResponseFormat(generateNotionPropertiesSchema(database), "notionProperties"),
  })

  const inputTokens = completion.usage?.prompt_tokens ?? 0
  const outputTokens = completion.usage?.completion_tokens ?? 0
  // input per milion tokens : $2
  // output per milion tokens : $8
  const inputPrice = (inputTokens * 0.002) / 1000
  const outputPrice = (outputTokens * 0.008) / 1000
  const totalPrice = inputPrice + outputPrice
  log.info(`Notion agent price: $${totalPrice.toFixed(4)} • ${completion.model}`)

  const parsedResponse = completion.choices[0]?.message?.content
  if (!parsedResponse) {
    throw new Error("Failed to generate task data")
  }

  log.info("Notion agent response", { response: parsedResponse })

  // Parse and validate the response against our Zod schema
  const validatedData = generateNotionPropertiesSchema(database).parse(JSON.parse(parsedResponse))

  // Extract properties and description from the validated data
  const propertiesFromResponse = validatedData.properties || {}
  const descriptionFromResponse = validatedData.description

  // Transform the Zod schema output to match Notion API format
  const propertiesData: Record<string, any> = {}

  // Filter out null values and transform to Notion API format
  Object.entries(propertiesFromResponse).forEach(([key, value]) => {
    if (value !== null) {
      if (value && typeof value === "object" && "date" in value && value.date) {
        const dateObj = { ...value.date } as any
        // Remove empty string end dates
        if (dateObj.end === "") {
          delete dateObj.end
        }
        propertiesData[key] = { date: dateObj }
      } else {
        propertiesData[key] = value
      }
    }
  })

  // Extract task title using the dynamic helper
  const titlePropertyName = findTitleProperty(database)
  const taskTitle = extractTaskTitle(propertiesData, titlePropertyName)

  // Create the page with properties and description
  const page = await newNotionPage(
    input.spaceId,
    databaseId,
    propertiesData,
    client,
    descriptionFromResponse || undefined,
  )
  log.info("Created Notion page", { pageId: page.id, page })

  return {
    pageId: page.id,
    url: `https://notion.so/${page.id.replace(/-/g, "")}`,
    taskTitle,
  }
}

export { createNotionPage }

const systemPrompt = `
# Identity
You are a task manager assistant for Inline Chat app. You create actionable tasks from chat messages by analyzing context and generating properly structured Notion database entries.

Instructions
  •	Create task titles that are actionable and accurate by reading chat context.
  • Include important parts of the conversation around the task in the page description. Include the decision making process and the reasoning behind the task if present in the full conversation.
  • Although including full important detailed data, keep it concise. Do not summarize quotes and important parts of the conversation.
  • The tone should be as if it were written by a reporter.
  • Use line breaks to make it more readable. 
  • Don't add any text like this: "The conversation context is:" - "Summery" - "Context"
  • Make it after the properties object: 
  {
    properties: { ... },
    description: [{object: "block",type: "paragraph",paragraph: {rich_text: [{type: "text",text: {content: "Your page description here"}}]}}]
  }
	•	Analyze the chat title and the conversation context to understand the task is related to which team or project and match it with notion database properties and set the team and project properties if there are any.
	•	Generate a properties object that EXACTLY matches the database schema structure. For empty non-text fields use null. Because otherwise Notion API will throw an error.
	•	Each property must use the exact property name and type structure from the database schema
	•	Follow Notion's API format for each property type
	•	Include only properties that exist in the database schema
  • You don't need to fill out every property, leave properties empty (null, not undefined or empty string) if they are not relevant to the task with the context provided. For example, a task can be created if it just has a title and an assignee (or DRI, or a field with person data type).
  • It is important to not create invalid properties by using "undefined" or empty strings "" in the properties object where it may be invalid in Notion's create page/database entry API.
	•	Match the tone and format of the example pages provided 
	•	Never set task in progress or done status - keep tasks in initial state
	•	For date properties (eg. "Due date"), if no date is specified, DO NOT include the property at all
	•	If a date is specified, use format: { "date": { "start": "YYYY-MM-DD" } } and calculate from today's date

	•	User Assignment Rules:
		▪	Creator and Assignee: ALWAYS set to the user that matches with the actor user ID who will do the task if found in the Notion users list.
		▪	Reporter/Watcher: Set to the user that matches with target message sender or who sent the message/report that the task is created for. (who will be notified when the task is completed)
		▪	Match chat participants with Notion users based on names, emails, or usernames from the notion_users list


`

function taskPrompt(
  notionUsers: NotionUser[],
  database: any,
  samplePages: any[],
  messages: ProcessedMessage[],
  targetMessage: ProcessedMessage,
  chatInfo: CachedChatInfo,
  participantNames: UserName[],
  currentUserId: number,
): string {
  // Limit messages to reduce token usage and improve speed
  const limitedMessages = messages.slice(-8) // Only use last 8 messages for context

  // Simplify sample pages to reduce token usage
  const simplifiedSamplePages = samplePages.slice(0, 2).map((page) => ({
    properties: page.properties,
    // Remove verbose fields to reduce tokens
  }))

  return `
Today's date: ${new Date().toISOString()}
Actor user ID: ${currentUserId}

Target message: ${formatMessage(targetMessage)}

<conversation_context>
Recent conversation:
${limitedMessages.map((message, index: number) => `[${index}] ${formatMessage(message)}`).join("\n")}
</conversation_context>

<context>
Chat: "${chatInfo?.title}"
</context>

<database_schema>
Properties: ${getPropertyDescriptions(database)}
</database_schema>

<sample_entries>
${JSON.stringify(simplifiedSamplePages, null, 2)}
</sample_entries>

<notion_users>
${JSON.stringify(notionUsers, null, 2)}
</notion_users>

<participants>
${JSON.stringify(participantNames, null, 2)}
</participants>
`
}
