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
import { systemPrompt12, systemPrompt14 } from "./prompts"

const log = new Log("NotionAgent", LogLevel.INFO)

async function createNotionPage(input: { spaceId: number; chatId: number; messageId: number; currentUserId: number }) {
  const startTime = Date.now()
  log.info("🕐 Starting Notion page creation", { ...input })

  if (!openaiClient) {
    throw new Error("OpenAI client not initialized")
  }

  // First, get the Notion client and database info
  const clientStart = Date.now()
  const { client, databaseId } = await getNotionClient(input.spaceId)
  log.info("🕐 Got Notion client", { durationSeconds: ((Date.now() - clientStart) / 1000).toFixed(3) })

  if (!databaseId) {
    Log.shared.error("No databaseId found", { spaceId: input.spaceId })
    throw new Error("No databaseId found")
  }

  // Run all data fetching operations in parallel - this is the biggest optimization
  const dataFetchStart = Date.now()
  const [notionUsers, database, samplePages, targetMessage, messages, chatInfo, participantNames] = await Promise.all([
    getNotionUsers(input.spaceId, client).then(formatNotionUsers),
    getActiveDatabaseData(input.spaceId, databaseId, client),
    getSampleDatabasePages(input.spaceId, databaseId, 3, client),
    MessageModel.getMessage(input.messageId, input.chatId),
    MessageModel.getMessagesAroundTarget(input.chatId, input.messageId, 20, 10),
    getCachedChatInfo(input.chatId),
    // Fetch participant names in parallel instead of sequentially
    getCachedChatInfo(input.chatId).then(async (chatInfo) => {
      if (!chatInfo?.participantUserIds) return []
      const names = await Promise.all(chatInfo.participantUserIds.map((userId) => getCachedUserName(userId)))
      return names.filter(filterFalsy)
    }),
  ])
  console.log("🌴 messages", messages)
  console.log("🌴 SMAPLE PAGES", samplePages)
  log.info("🕐 Completed parallel data fetching", {
    durationSeconds: ((Date.now() - dataFetchStart) / 1000).toFixed(3),
  })

  log.info("Creating Notion page", { database: database?.id, chatTitle: chatInfo?.title, chatId: input.chatId })

  if (!database) {
    throw new Error("No active database found")
  }

  if (!chatInfo) {
    throw new Error("Could not find chat information in database")
  }

  const promptStart = Date.now()
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
  console.log("🌴 userPrompt", userPrompt)
  log.info("🕐 Generated user prompt", { durationSeconds: ((Date.now() - promptStart) / 1000).toFixed(3) })

  const openaiStart = Date.now()

  if (!openaiClient) {
    throw new Error("OpenAI client not initialized")
  }

  // Generate and validate the schema before sending to OpenAI
  const schema = generateNotionPropertiesSchema(database)
  log.info("Generated Notion properties schema", {
    databaseId: database.id,
    totalProperties: Object.keys(database.properties || {}).length,
  })

  // throw new Error("test")
  const completion = await openaiClient.chat.completions.create({
    model: "gpt-4.1",

    messages: [
      {
        role: "system",
        content: systemPrompt14,
      },
      {
        role: "user",
        content: userPrompt,
      },
    ],
    // response_format: { type: "text" },
    response_format: zodResponseFormat(schema, "notionProperties"),
  })
  log.info("🕐 OpenAI completion finished", { durationSeconds: ((Date.now() - openaiStart) / 1000).toFixed(3) })

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

  const parseStart = Date.now()
  const validatedData = schema.parse(JSON.parse(parsedResponse))
  log.info("🕐 Parsed and validated response", { durationSeconds: ((Date.now() - parseStart) / 1000).toFixed(3) })

  // Extract properties and description from the validated data
  const propertiesFromResponse = validatedData.properties || {}
  const descriptionFromResponse = validatedData.description

  // Use hardcoded icon instead of AI-generated one
  const iconFromResponse = {
    type: "external" as const,
    external: {
      url: "https://www.notion.so/icons/circle_lightgray.svg",
    },
  }

  // Transform simplified blocks to proper Notion format
  const transformedDescription =
    descriptionFromResponse?.map((block: any) => {
      const notionBlock: any = {
        object: "block",
        type: block.type,
      }

      if (block.type === "paragraph") {
        notionBlock.paragraph = {
          rich_text:
            block.rich_text?.map((rt: any) => ({
              type: "text",
              text: {
                content: rt.content || "",
                link: rt.url ? { url: rt.url } : null,
              },
              annotations: {
                bold: false,
                italic: false,
                strikethrough: false,
                underline: false,
                code: false,
                color: "default",
              },
              plain_text: rt.content || "",
              href: rt.url || null,
            })) || [],
          color: "default",
        }
      } else if (block.type === "bulleted_list_item") {
        notionBlock.bulleted_list_item = {
          rich_text:
            block.rich_text?.map((rt: any) => ({
              type: "text",
              text: {
                content: rt.content || "",
                link: rt.url ? { url: rt.url } : null,
              },
              annotations: {
                bold: false,
                italic: false,
                strikethrough: false,
                underline: false,
                code: false,
                color: "default",
              },
              plain_text: rt.content || "",
              href: rt.url || null,
            })) || [],
          color: "default",
        }
      }

      return notionBlock
    }) || undefined

  // Transform the Zod schema output to match Notion API format
  const transformStart = Date.now()
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
  log.info("🕐 Transformed properties data", { durationSeconds: ((Date.now() - transformStart) / 1000).toFixed(3) })

  // Create the page with properties and description
  const pageCreateStart = Date.now()

  if (!databaseId) {
    throw new Error("Database ID is required but was null")
  }

  const page = await newNotionPage(
    input.spaceId,
    databaseId,
    propertiesData,
    client,
    transformedDescription || undefined,
    iconFromResponse,
  )
  log.info("🕐 Created Notion page", {
    pageId: page.id,
    durationSeconds: ((Date.now() - pageCreateStart) / 1000).toFixed(3),
  })

  const totalDuration = Date.now() - startTime
  log.info("🕐 Notion page creation completed", {
    pageId: page.id,
    totalDurationSeconds: (totalDuration / 1000).toFixed(3),
    taskTitle,
  })

  return {
    pageId: page.id,
    url: `https://notion.so/${page.id.replace(/-/g, "")}`,
    taskTitle,
  }
}

export { createNotionPage }

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

  // Simplify sample pages to reduce token usage - now includes content
  const simplifiedSamplePages = samplePages.slice(0, 2).map((page) => ({
    properties: page.properties,
    content: page.content, // Now includes the page content/body
  }))

  // Extract status options from database schema
  const statusProperty = database.properties?.Status || database.properties?.status
  const statusOptions = statusProperty?.status?.options?.map((option: any) => option.name) || []

  return `
Today's date: ${new Date().toISOString()}
Actor user ID: ${currentUserId}

Target message: ${formatMessage(targetMessage)}

<active-team-context>
${JSON.stringify(process.env.WANVER_TRANSLATION_CONTEXT, null, 2)}
</active-team-context>

<conversation_context>
Recent conversation:
${limitedMessages.map((message, index: number) => `[${index}] ${formatMessage(message)}`).join("\n")}
</conversation_context>

<context>
Chat: "${chatInfo?.title}"
</context>

<database_schema>
Properties: ${getPropertyDescriptions(database)}

${statusOptions.length > 0 ? `Available Status Options: ${statusOptions.join(", ")}` : ""}
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
