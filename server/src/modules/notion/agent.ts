import { openaiClient } from "@in/server/libs/openAI"
import { getActiveDatabaseData, getNotionUsers, newNotionPage, getSampleDatabasePages, getNotionClient } from "./notion"
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

  const notion = await getNotionClient(input.spaceId)

  const [notionUsers, database, samplePages, targetMessage, messages, chatInfo] = await Promise.all([
    getNotionUsers(input.spaceId, notion),
    getActiveDatabaseData(input.spaceId, notion),
    getSampleDatabasePages(input.spaceId, 10, notion),
    MessageModel.getMessage(input.messageId, input.chatId),
    MessageModel.getMessagesAroundTarget(input.chatId, input.messageId, 15, 15),
    getCachedChatInfo(input.chatId),
  ])

  let participantNames = (
    await Promise.all((chatInfo?.participantUserIds ?? []).map((userId) => getCachedUserName(userId)))
  ).filter(filterFalsy)

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
    //model: "gpt-4o-2024-08-06",
    model: process.env.NODE_ENV === "production" ? "gpt-4.1" : "gpt-4.1-mini",
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

  // Transform the Zod schema output to match Notion API format
  const propertiesData: Record<string, any> = {}

  // Filter out null values and transform to Notion API format
  Object.entries(validatedData).forEach(([key, value]) => {
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

  const page = await newNotionPage(input.spaceId, database.id, propertiesData)
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
	•	Analyze the chat title and the conversation context to understand the task is related to which team or project and match it with notion database properties and set the team and project properties if there are any.
	•	Create task titles that are actionable and accurate by reading chat context around the target message
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
	•	Generate ONLY the properties object that matches the provided schema structure - do not include parent or top-level fields

# Examples
Note: The examples below demonstrate the user assignment pattern. You must use the EXACT property names from the database schema provided.

<example_context>
Messages: [
  "Sarah: We need to fix the login bug",
  "Mike: The deadline is tomorrow", 
  "John: Dena can you handle this?"
]
Target Message: "Dena can you handle this?" (fromId: 456)
Current User ID: 123
Database has properties: "Name" (title), "Due Date" (date), "Status" (status), "Assignee" (people), "Creator" (people), "Watcher" (people)
Notion Users: [
  {"id": "notion_user_123", "name": "Current User", "email": "current@example.com"},
  {"id": "notion_user_456", "name": "John", "email": "john@example.com"}
]
</example_context>

<assistant_response>
{
  "Name": {
    "title": [{ "text": { "content": "Fix login bug" } }]
  },
  "Due Date": {
    "date": { "start": "2024-01-16" }
  },
  "Status": {
    "status": { "name": "Not started" }
  },
  "Assignee": {
    "people": [{ "id": "notion_user_123" }]
  },
  "Creator": {
    "people": [{ "id": "notion_user_123" }]
  },
  "Watcher": {
    "people": [{ "id": "notion_user_456" }]
  }
}
</assistant_response>

<example_context>
Messages: [
  "Alex: Can you update the documentation?",
  "Dena: Sure, when do you need it?",
  "Alex: By Friday would be great"
]
Target Message: "Can you update the documentation?" (fromId: 789)
Current User ID: 456
Database has properties: "Task" (title), "Deadline" (date), "State" (status), "Assigned To" (people), "Reporter" (people)
Notion Users: [
  {"id": "notion_user_456", "name": "Dena", "email": "dena@example.com"},
  {"id": "notion_user_789", "name": "Alex", "email": "alex@example.com"}
]
</example_context>

<assistant_response>
{
  "Task": {
    "title": [{ "text": { "content": "Update documentation" } }]
  },
  "Deadline": {
    "date": { "start": "2024-01-19" }
  },
  "State": {
    "status": { "name": "Not started" }
  },
  "Assigned To": {
    "people": [{ "id": "notion_user_456" }]
  },
  "Reporter": {
    "people": [{ "id": "notion_user_789" }]
  }
}
</assistant_response>
`

function taskPrompt(
  notionUsers: any,
  database: any,
  samplePages: any[],
  messages: ProcessedMessage[],
  targetMessage: ProcessedMessage,
  chatInfo: CachedChatInfo,
  participantNames: UserName[],
  currentUserId: number,
): string {
  return `
Today's date: ${new Date().toISOString()}
Actor user ID: ${currentUserId}

Target message (the message that user started the task for in the chat):
${formatMessage(targetMessage)}

<nearby_messages_context>
Full conversation context (analyze ALL messages for due dates):
${messages.map((message, index: number) => `[${index}] ${formatMessage(message)}`).join("\n")}
</nearby_messages_context>

<team_context>
Active team: Wanver
if the team data I gave you was matched to this team, use the knowledge in it to create more accurate properties for the task
Context: ${WANVER_TRANSLATION_CONTEXT}
</team_context>

<chat_context_analysis>
Chat title: "${chatInfo?.title}"
Instructions for team identification:
	•	Analyze the chat title and chat context to detect which team or project this task belongs to
</chat_context_analysis>

<database_schema>
Available properties: ${getPropertyDescriptions(database)}
Full schema:
${JSON.stringify(database, null, 2)}
</database_schema>

<sample_notion_entries>
${JSON.stringify(samplePages, null, 2)}
</sample_notion_entries>

<notion_users>
${JSON.stringify(notionUsers, null, 2)}
</notion_users>

<chat_participants>
 ${JSON.stringify(participantNames, null, 2)}
</chat_participants>
`
}
