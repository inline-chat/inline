import { openaiClient } from "@in/server/libs/openAI"
import { getActiveDatabaseData, getCurrentNotionUser, getNotionUsers, newNotionPage } from "./notion"
import { MessageModel } from "@in/server/db/models/messages"
import { Log } from "@in/server/utils/log"
import { WANVER_TRANSLATION_CONTEXT } from "@in/server/env"

const log = new Log("NotionAgent")

export enum AgentType {
  TASK = "task",
}

// Optimized for create task
async function createNotionPage(input: {
  spaceId: number
  messagesIds: number[]
  chatId: number
  messageId: number
  currentUserId: number
  agentType?: AgentType
}) {
  const { agentType = AgentType.TASK } = input
  if (!openaiClient) {
    throw new Error("OpenAI client not initialized")
  }

  const notionUsers = await getNotionUsers(input.spaceId)
  const database = await getActiveDatabaseData(input.spaceId)

  log.info("Creating Notion page", { database })

  if (!database) {
    throw new Error("No active database found")
  }

  const messages = await Promise.all(
    input.messagesIds.map((messageId) => MessageModel.getMessage(messageId, input.chatId)),
  )

  const targetMessage = await MessageModel.getMessage(input.messageId, input.chatId)

  const currentNotionUser = await getCurrentNotionUser(input.spaceId, input.currentUserId)

  const taskPrompt = `
  You are a task manager assistant in a chat app called Inline. You create tasks from messages in a chat. You make task title actionable and accurate by reading chat context around the target message.
  We have an active team named Wanver. They will mostly use your service to create tasks from messages in a chat. this is related context about them:
  ${WANVER_TRANSLATION_CONTEXT}.

  This is the Notion database we're using to track issues in it. We need to create a new page with this database structure:
  ${JSON.stringify(database, null, 2)}
  
  This is the messages around the target message that triggered to create a new task maybe add context to the task. Analayze them and take important information from them to make a good and actionable task title:
  ${messages.map((m) => `${m.from.firstName}: ${m.text || ""}`).join("\n")}

  This is the target message text that triggered to create a new task:
  ${targetMessage.text || ""}

  Notion Users if needed to set in a property:
  ${JSON.stringify(notionUsers, null, 2)}

  Make sure the current user is the assignee and creator of the page:
  ${JSON.stringify(currentNotionUser, null, 2)}

  Generate a properties object that EXACTLY matches the database schema structure. Each property must:
  1. Use the exact property name from the database schema
  2. Have the correct property type structure as defined in the database schema
  3. Follow Notion's API format for each property type
  4. Include only properties that exist in the database schema

  Generate ONLY the properties object for a Notion page - do not include parent or any top-level fields.
  `

  const completion = await openaiClient.chat.completions.create({
    model: process.env.NODE_ENV === "development" ? "gpt-4.1-nano" : "gpt-4.1-mini",
    messages: [
      {
        role: "system",
        content:
          "You are a helpful assistant that creates Notion pages from chat conversations. Generate valid JSON that matches the Notion database structure. The properties object must match exactly with the database schema property names and types. For example, if the database has a 'Task name' property of type 'title', the response should have 'Task name' (not 'Title') with the correct title structure. Each property must have its correct type structure (title, rich_text, select, people, etc.) as defined in the database schema.",
      },
      {
        role: "user",
        content: agentType === AgentType.TASK ? taskPrompt : "",
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

  const page = await newNotionPage(input.spaceId, database.id, propertiesData)
  log.info("Created Notion page", { pageId: page.id, page })

  return {
    pageId: page.id,
    url: `https://notion.so/${page.id.replace(/-/g, "")}`,
  }
}

export { createNotionPage }
