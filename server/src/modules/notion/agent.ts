import { openaiClient } from "@in/server/libs/openAI"
import {
  getActiveDatabaseData,
  getNotionUsers,
  newNotionPage,
  getSampleDatabasePages,
  getNotionClient,
  formatNotionUsers,
  persistCanonicalNotionParentId,
  resolveSelectedNotionParent,
  type NotionUser,
} from "./notion"
import { MessageModel, type ProcessedMessage } from "@in/server/db/models/messages"
import { Log, LogLevel } from "@in/server/utils/log"
import { HARDCODED_TRANSLATION_CONTEXT, isDev } from "@in/server/env"
import { getCachedChatInfo, type CachedChatInfo } from "@in/server/modules/cache/chatInfo"
import { getCachedUserName, type UserName } from "@in/server/modules/cache/userNames"
import { filterFalsy } from "@in/server/utils/filter"
import { findTitleProperty, extractTaskTitle, getPropertyDescriptions } from "./schemaGenerator"
import { formatMessage } from "@in/server/modules/notifications/eval"
import { systemPrompt14 } from "./prompts"
import { parseNotionAgentResponse } from "./agentResponse"
import { NOTION_SETUP_ERROR_MESSAGES } from "./errors"

const log = new Log("NotionAgent", LogLevel.INFO)

const logDevTelemetry = (message: string, metadata: Record<string, unknown>) => {
  if (isDev) {
    log.info(message, metadata)
  }
}

const logProdTelemetry = (message: string, metadata: Record<string, unknown>) => {
  if (!isDev) {
    log.info(message, metadata)
  }
}

const errorTelemetry = (error: unknown) => ({
  errorName: error instanceof Error ? error.name : "UnknownError",
  errorMessage: error instanceof Error ? error.message : String(error),
})

const isNotionPropertyValueObject = (value: unknown): value is Record<string, unknown> => {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function inlineUserDisplayName(user: UserName | undefined, fallbackUserId: number): string {
  if (user) {
    const fullName = [user.firstName, user.lastName].filter(Boolean).join(" ")
    if (fullName) return fullName
    if (user.username) return user.username
    if (user.email) return user.email
    if (user.phone) return user.phone
  }

  return `User ${fallbackUserId}`
}

async function createNotionPage(input: { spaceId: number; chatId: number; messageId: number; currentUserId: number }) {
  const startTime = Date.now()
  let stage = "start"
  const telemetry = {
    spaceId: input.spaceId,
    chatId: input.chatId,
    messageId: input.messageId,
  }
  const devTelemetry = { ...telemetry, currentUserId: input.currentUserId }

  logProdTelemetry("Notion page creation started", telemetry)
  logDevTelemetry("Starting Notion page creation", input)

  try {
    if (!openaiClient) {
      throw new Error("OpenAI client not initialized")
    }

    // First, get the Notion client and database info
    stage = "load_notion_client"
    const clientStart = Date.now()
    const { client, databaseId: savedParentId } = await getNotionClient(input.spaceId)
    logDevTelemetry("Loaded Notion client", {
      spaceId: input.spaceId,
      durationMs: Date.now() - clientStart,
    })

    if (!savedParentId) {
      Log.shared.error("No notion parent found", devTelemetry)
      throw new Error(NOTION_SETUP_ERROR_MESSAGES.parentMissing)
    }

    const selectedParent = await resolveSelectedNotionParent(input.spaceId, savedParentId, client)
    if (selectedParent.wasLegacyDatabaseSelection) {
      await persistCanonicalNotionParentId(input.spaceId, savedParentId, selectedParent.dataSourceId)
    }

    // Run all data fetching operations in parallel - this is the biggest optimization
    stage = "load_notion_context"
    const dataFetchStart = Date.now()
    const [notionUsers, dataSource, samplePages, targetMessage, messages, chatInfo, participantNames, currentUserName] =
      await Promise.all([
        getNotionUsers(input.spaceId, client).then(formatNotionUsers),
        getActiveDatabaseData(input.spaceId, selectedParent.dataSourceId, client),
        getSampleDatabasePages(input.spaceId, selectedParent.dataSourceId, 3, client),
        MessageModel.getMessage(input.messageId, input.chatId),
        MessageModel.getMessagesAroundTarget(input.chatId, input.messageId, 20, 10),
        getCachedChatInfo(input.chatId),
        // Fetch participant names in parallel instead of sequentially
        getCachedChatInfo(input.chatId).then(async (chatInfo) => {
          if (!chatInfo?.participantUserIds) return []
          const names = await Promise.all(chatInfo.participantUserIds.map((userId) => getCachedUserName(userId)))
          return names.filter(filterFalsy)
        }),
        getCachedUserName(input.currentUserId),
      ])
    logDevTelemetry("Loaded Notion task context", {
      spaceId: input.spaceId,
      chatId: input.chatId,
      messageId: input.messageId,
      durationMs: Date.now() - dataFetchStart,
      notionUsersCount: notionUsers.length,
      samplePagesCount: samplePages.length,
      participantCount: participantNames.length,
      contextMessageCount: messages.length,
    })

    logDevTelemetry("Preparing Notion page payload", {
      spaceId: input.spaceId,
      chatId: input.chatId,
      databaseId: selectedParent.databaseId,
      dataSourceId: selectedParent.dataSourceId,
    })

    if (!dataSource) {
      throw new Error("No active data source found")
    }

    if (!chatInfo) {
      throw new Error("Could not find chat information in database")
    }

    stage = "build_prompt"
    const promptStart = Date.now()
    const userPrompt = taskPrompt(
      notionUsers,
      dataSource,
      samplePages,
      messages,
      targetMessage,
      chatInfo,
      participantNames,
      currentUserName,
      input.currentUserId,
    )
    logDevTelemetry("Built Notion task prompt", {
      spaceId: input.spaceId,
      chatId: input.chatId,
      messageId: input.messageId,
      durationMs: Date.now() - promptStart,
      promptLength: userPrompt.length,
    })

    stage = "openai_completion"
    const openaiStart = Date.now()
    const completion = await openaiClient.chat.completions.create({
      model: "gpt-5.4",
      verbosity: "medium",
      reasoning_effort: "low", // was "hard"

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
      response_format: { type: "json_object" },
    })
    logDevTelemetry("Received Notion agent completion", {
      spaceId: input.spaceId,
      chatId: input.chatId,
      messageId: input.messageId,
      durationMs: Date.now() - openaiStart,
    })

    const inputTokens = completion.usage?.prompt_tokens ?? 0
    const outputTokens = completion.usage?.completion_tokens ?? 0
    // input per milion tokens : $2
    // output per milion tokens : $8
    const inputPrice = (inputTokens * 0.002) / 1000
    const outputPrice = (outputTokens * 0.008) / 1000
    const totalPrice = inputPrice + outputPrice
    const completionDurationMs = Date.now() - openaiStart
    logProdTelemetry("Notion agent completion telemetry", {
      ...telemetry,
      completionDurationMs,
      inputTokens,
      outputTokens,
      estimatedCostUsd: Number(totalPrice.toFixed(4)),
    })
    logDevTelemetry("Notion agent usage", {
      ...devTelemetry,
      model: completion.model,
      inputTokens,
      outputTokens,
      estimatedCostUsd: Number(totalPrice.toFixed(4)),
    })

    const responseMessage = completion.choices[0]?.message
    if (!responseMessage?.content) {
      throw new Error("Failed to generate task data")
    }
    logDevTelemetry("Notion agent raw response", {
      ...devTelemetry,
      responseLength: responseMessage.content.length,
      responseContent: responseMessage.content,
    })

    stage = "parse_agent_response"
    const parseStart = Date.now()
    let validatedData: ReturnType<typeof parseNotionAgentResponse>
    try {
      validatedData = parseNotionAgentResponse({
        content: responseMessage?.content,
      })
    } catch (err) {
      log.error("Failed to parse Notion agent JSON", err, {
        ...devTelemetry,
        responseLength: responseMessage?.content?.length ?? 0,
      })
      throw new Error("Notion agent returned invalid JSON")
    }
    logDevTelemetry("Parsed Notion agent JSON", {
      ...devTelemetry,
      durationMs: Date.now() - parseStart,
    })

    const propertiesFromResponse = validatedData?.properties || {}
    const markdownFromResponse = validatedData?.markdown

    // Use hardcoded icon instead of AI-generated one
    const iconFromResponse = {
      type: "external" as const,
      external: {
        url: "https://www.notion.so/icons/circle_lightgray.svg",
      },
    }

    // Normalize model output to match Notion API format
    stage = "transform_payload"
    const transformStart = Date.now()
    const propertiesData: Record<string, any> = {}

    // Filter out null values and transform to Notion API format
    Object.entries(propertiesFromResponse).forEach(([key, value]) => {
      if (value !== null) {
        if (!isNotionPropertyValueObject(value)) {
          logDevTelemetry("Skipping invalid non-object Notion property value", {
            ...devTelemetry,
            propertyName: key,
            valueType: typeof value,
          })
          return
        }

        const dateValue = value["date"]
        if ("date" in value && dateValue && typeof dateValue === "object" && !Array.isArray(dateValue)) {
          const dateObj = { ...dateValue } as any
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
    const titlePropertyName = findTitleProperty(dataSource)
    const taskTitle = extractTaskTitle(propertiesData, titlePropertyName)
    logDevTelemetry("Transformed Notion properties payload", {
      ...devTelemetry,
      durationMs: Date.now() - transformStart,
      propertiesCount: Object.keys(propertiesData).length,
      markdownLength: markdownFromResponse?.length ?? 0,
    })

    // Create the page with properties and markdown content
    stage = "create_notion_page"
    const pageCreateStart = Date.now()

    const page = await newNotionPage(
      input.spaceId,
      selectedParent.dataSourceId,
      propertiesData,
      client,
      markdownFromResponse,
      iconFromResponse,
    )
    logDevTelemetry("Created Notion page", {
      ...devTelemetry,
      hasPageId: Boolean(page.id),
      durationMs: Date.now() - pageCreateStart,
    })

    const totalDuration = Date.now() - startTime
    logProdTelemetry("Notion page creation completed", {
      ...telemetry,
      totalDurationMs: totalDuration,
      hasTaskTitle: Boolean(taskTitle),
    })
    logDevTelemetry("Notion page creation completed", {
      ...devTelemetry,
      totalDurationMs: totalDuration,
      hasTaskTitle: Boolean(taskTitle),
    })

    return {
      pageId: page.id,
      url: `https://notion.so/${page.id.replace(/-/g, "")}`,
      taskTitle,
    }
  } catch (error) {
    const totalDuration = Date.now() - startTime
    log.error("Notion page creation failed", error, {
      ...devTelemetry,
      stage,
      totalDurationMs: totalDuration,
      ...errorTelemetry(error),
    })
    throw error
  }
}

export { createNotionPage }

function taskPrompt(
  notionUsers: NotionUser[],
  dataSource: any,
  samplePages: any[],
  messages: ProcessedMessage[],
  targetMessage: ProcessedMessage,
  chatInfo: CachedChatInfo,
  participantNames: UserName[],
  currentUserName: UserName | undefined,
  currentUserId: number,
): string {
  // Limit messages to reduce token usage and improve speed
  const limitedMessages = messages.slice(-8) // Only use last 8 messages for context

  // Simplify sample pages to reduce token usage - now includes content
  const simplifiedSamplePages = samplePages.slice(0, 2).map((page) => ({
    properties: page.properties,
    markdown: typeof page.markdown === "string" ? page.markdown.slice(0, 4000) : "",
  }))

  // Extract status options from data source schema
  const statusProperty = dataSource.properties?.Status || dataSource.properties?.status
  const statusOptions = statusProperty?.status?.options?.map((option: any) => option.name) || []

  const actor = currentUserName ?? participantNames.find((p) => p.id === currentUserId)
  const actorDisplayName = inlineUserDisplayName(actor, currentUserId)

  return `
<metadata>
today: ${new Date().toISOString()}
actor_inline_user_id: ${currentUserId}
actor_display_name: ${actorDisplayName}
</metadata>

<context>
Chat: "${chatInfo?.title}"
</context>

<target_message>
${formatMessage(targetMessage)}
</target_message>

<active-team-context>
${HARDCODED_TRANSLATION_CONTEXT ?? ""}
</active-team-context>

<conversation_context>
${limitedMessages.map((message) => formatMessage(message)).join("\n")}
</conversation_context>

<database_schema>
Properties: ${getPropertyDescriptions(dataSource)}

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
