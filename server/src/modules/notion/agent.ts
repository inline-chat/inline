import { openaiClient } from "@in/server/libs/openAI"
import { getActiveDatabaseData, getNotionUsers, newNotionPage, getSampleDatabasePages } from "./notion"
import { MessageModel } from "@in/server/db/models/messages"
import { Log } from "@in/server/utils/log"
import { WANVER_TRANSLATION_CONTEXT } from "@in/server/env"
import { db } from "@in/server/db"
import { users, chats } from "@in/server/db/schema"
import { eq } from "drizzle-orm"

const log = new Log("NotionAgent")

async function createNotionPage(input: {
  spaceId: number
  messagesIds: number[]
  chatId: number
  messageId: number
  currentUserId: number
}) {
  if (!openaiClient) {
    throw new Error("OpenAI client not initialized")
  }

  const [notionUsers, database, samplePages, messages, targetMessage, currentUser, chatInfo] = await Promise.all([
    getNotionUsers(input.spaceId),
    getActiveDatabaseData(input.spaceId),
    getSampleDatabasePages(input.spaceId),
    Promise.all(input.messagesIds.map((messageId) => MessageModel.getMessage(messageId, input.chatId))),
    MessageModel.getMessage(input.messageId, input.chatId),
    db
      .select()
      .from(users)
      .where(eq(users.id, input.currentUserId))
      .then((result) => result[0]),
    db
      .select()
      .from(chats)
      .where(eq(chats.id, input.chatId))
      .then((result) => result[0]),
  ])

  log.info("Creating Notion page", { database, chatTitle: chatInfo?.title, chatId: input.chatId })

  if (!database) {
    throw new Error("No active database found")
  }

  if (!currentUser) {
    throw new Error("Could not find target message sender in database")
  }

  if (!chatInfo) {
    throw new Error("Could not find chat information in database")
  }

  const [reportedByUser] = await Promise.all([
    db
      .select()
      .from(users)
      .where(eq(users.id, targetMessage.from.id))
      .then((result) => result[0]),
  ])

  if (!reportedByUser) {
    throw new Error("Could not find reported by user in database")
  }

  const [findUserCompletion, findReportedByUserCompletion] = await Promise.all([
    openaiClient.chat.completions.create({
      model: "gpt-4.1-mini",
      messages: [
        {
          role: "user",
          content: findUserPrompt(notionUsers, currentUser),
        },
      ],
      response_format: { type: "json_object" },
    }),
    openaiClient.chat.completions.create({
      model: "gpt-4.1-mini",
      messages: [
        {
          role: "user",
          content: findUserPrompt(notionUsers, reportedByUser),
        },
      ],
      response_format: { type: "json_object" },
    }),
  ])

  const findUserContent = findUserCompletion.choices[0]?.message?.content
  if (!findUserContent) {
    throw new Error("Failed to find user")
  }

  const findReportedByUserContent = findReportedByUserCompletion.choices[0]?.message?.content
  if (!findReportedByUserContent) {
    throw new Error("Failed to find user")
  }

  const [matchedUser, matchedReportedByUser] = await Promise.all([
    JSON.parse(findUserContent),
    JSON.parse(findReportedByUserContent),
  ])

  const completion = await openaiClient.chat.completions.create({
    model: "gpt-4.1",
    messages: [
      {
        role: "user",
        content: taskPrompt(
          notionUsers,
          currentUser,
          database,
          samplePages,
          messages,
          targetMessage,
          chatInfo,
          matchedUser,
          matchedReportedByUser,
        ),
      },
    ],
    response_format: { type: "json_object" },
  })

  const messageContent = completion.choices[0]?.message?.content
  if (!messageContent) {
    throw new Error("Failed to generate task data")
  }

  const parsedData = JSON.parse(messageContent)

  const propertiesData = parsedData.taskData || parsedData

  // Extract task title from the properties
  let taskTitle = null
  if (propertiesData.Title?.title?.[0]?.text?.content) {
    taskTitle = propertiesData.Title.title[0].text.content
  } else if (propertiesData.title?.title?.[0]?.text?.content) {
    taskTitle = propertiesData.title.title[0].text.content
  } else if (propertiesData.Name?.title?.[0]?.text?.content) {
    taskTitle = propertiesData.Name.title[0].text.content
  }

  const page = await newNotionPage(input.spaceId, database.id, propertiesData)
  log.info("Created Notion page", { pageId: page.id, page })

  return {
    pageId: page.id,
    url: `https://notion.so/${page.id.replace(/-/g, "")}`,
    taskTitle,
  }
}

export { createNotionPage }

function findUserPrompt(notionUsers: any, currentUser: any) {
  return `
  # Identity
  You are a user matching assistant for a data synchronization system. You analyze user data from an app and find the most relevant matching user from a Notion database.

  # Instructions
  
  - Compare the provided app user data with the list of Notion users
  - Find the Notion user that best matches the app user based on available fields (name, email, username, etc.)
  - Consider partial matches and similar variations of names/usernames
  - Prioritize exact email matches over name similarities
  - Return the complete Notion user object that represents the best match as a JSON object
  - If no reasonable match is found, return null

  # Examples
  <example_context>
  App User: { name: "John Smith", email: "john.smith@company.com" }
  Notion Users: [
    { id: "1", name: "John S.", email: "john.smith@company.com", username: "jsmith" },
    { id: "2", name: "Jane Doe", email: "jane@company.com", username: "jdoe" }
  ]
  </example_context>
  <assistant_response>
  { id: "1", name: "John S.", email: "john.smith@company.com", username: "jsmith" }
  </assistant_response>

  # Data
  <notion_users>
  ${JSON.stringify(notionUsers, null, 2)}
  </notion_users>
  
  <app_user>
  ${JSON.stringify(currentUser, null, 2)}
  </app_user>
  `
}

function taskPrompt(
  notionUsers: any,
  currentUser: any,
  database: any,
  samplePages: any,
  messages: any,
  targetMessage: any,
  chatInfo: any,
  matchedUser: any,
  matchedReportedByUser: any,
) {
  return `
  # Identity
  You are a task manager assistant for Inline Chat app. You create actionable tasks from chat messages by analyzing context and generating properly structured Notion database entries.

  # Instructions
  
  - Analyze the chat title and the conversation context to understand the task is related to which team or project and match it with notion database properties and set the team and project properties if there are any.
  - Create task titles that are actionable and accurate by reading chat context around the target message
  - Generate a properties object that EXACTLY matches the database schema structure
  - Each property must use the exact property name and type structure from the database schema
  - Follow Notion's API format for each property type
  - Include only properties that exist in the database schema
  - Match the tone and format of the example pages provided for example if the title of pages has emoji or is Uppercase, do the same for the task title
  - Never set task in progress or done status - keep tasks in initial state
  - For date properties (like "Due date"), if no date is specified, DO NOT include the property at all
  - If a date is specified, use format: { "date": { "start": "YYYY-MM-DD" } }
  - **Due Date Detection**: Analyze ALL messages in the conversation context for time expressions, not just the target message
  - **Context Analysis**: Look for due dates mentioned in previous or subsequent messages that relate to the task
  - **Date Sources**: Check for dates in:
    - Target message: "fix the bug till tomorrow"
    - Previous messages: "We need this done by Friday" followed by "John can you handle this?"
    - Subsequent messages: "Can you do this?" followed by "Sure, I'll have it ready by Monday"
    - Related context: "The deadline is next week" mentioned earlier in conversation
  - **Date Calculation**: Use today's date as the reference point to calculate the actual due date
  - **Relative Date Examples**: 
    - "till tomorrow" = today + 1 day
    - "by Friday" = today + 5 days
    - "until next week" = today + 7 days
    - "by end of day" = today 
    - "in 3 days" = today + 3 days
    - "next Monday" = following Monday from today
    - "by the 15th" = 15th of current/next month depending on context
  - Set the current user as assignee and creator of the page
  - Set the reported by user as the watch of the page (watch or any field that is related to overseer of the task)
  - Generate ONLY the properties object as a JSON object - do not include parent or top-level fields
  
  # Examples
  <example_context>
  Messages: [
    "Sarah: We need to fix the login bug",
    "Mike: The deadline is tomorrow",
    "John: Dena can you handle this?"
  ]
  Target Message: "Dena can you handle this?"
  </example_context>
  <assistant_response>
  {
    "Title": {
      "title": [{ "text": { "content": "Fix login bug" } }]
    },
    "Due date": {
      "date": { "start": "2024-01-16" }
    },
    "Status": {
      "status": { "name": "Not started" }
    },
    "Assignee": {
      "people": [{ "id": "user_123" }]
    }
  }
  </assistant_response>

  <example_context>
  Messages: [
    "Alex: Can you update the documentation?",
    "Dena: Sure, when do you need it?",
    "Alex: By Friday would be great"
  ]
  Target Message: "Can you update the documentation?" 
  </example_context>
  <assistant_response>
  {
    "Title": {
      "title": [{ "text": { "content": "Update documentation" } }]
    },
    "Due date": {
      "date": { "start": "2024-01-19" }
    },
    "Status": {
      "status": { "name": "Not started" }
    }
  }
  </assistant_response>

  # Context
  <team_context>
  Active team: Wanver
  if the team data I gave you was matched to this team, use the knoledge in it to create more accurate properties for the task
  Context: ${WANVER_TRANSLATION_CONTEXT}
  </team_context>

  <chat_context_analysis>
  Chat title: "${chatInfo?.title || "No title"}"
  
  Instructions for team identification:
  - Analyze the chat title to determine which team or project this task belongs to
  - Look for team names, project names, or department indicators in the chat title
  - Use this information to categorize the task appropriately in the database properties
  - If the chat title indicates a specific team (e.g., "Engineering Team", "Marketing Discussion", "Project Alpha"), 
    reflect this in the task properties where applicable
  </chat_context_analysis>

  <database_schema>
  ${JSON.stringify(database, null, 2)}
  </database_schema>

  <sample_pages>
  ${JSON.stringify(samplePages, null, 2)}
  </sample_pages>

  <chat_context>
  Full conversation context (analyze ALL messages for due dates):
  ${messages
    .map(
      (m: any, index: number) =>
        `[${index}] 
      messageId: ${m.messageId}
       userId: ${m.from.id} 
       sender name: ${m.from.firstName} 
       Date: ${m.date || m.date || ""}
       Text: ${m.text || ""}
       replyToId: ${m.replyToMsgId || ""}
    `,
    )
    .join("\n")}
  </chat_context>

  <target_message>
  Text: ${targetMessage.text || ""}
  Timestamp: ${new Date().toISOString()}
  Message Index: ${messages.findIndex((m: any) => m.messageId === targetMessage.messageId)}
  </target_message>

  <notion_users>
  ${JSON.stringify(notionUsers, null, 2)}
  </notion_users>

  <current_user_assignee>
  ${JSON.stringify(matchedUser, null, 2)}
  </current_user_assignee>

  <reported_by_user(watch)>
  ${JSON.stringify(matchedReportedByUser, null, 2)}
  </reported_by_user(watch)>
  `
}
