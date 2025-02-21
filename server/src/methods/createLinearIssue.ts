import { Optional, Type, type Static } from "@sinclair/typebox"
import { eq } from "drizzle-orm"
import OpenAI from "openai"
import { spaces, users } from "../db/schema"
import { db } from "../db"
import {
  createIssue,
  generateIssueLink,
  getLinearIssueLabels,
  getLinearIssueStatuses,
  getLinearOrg,
  getLinearTeams,
  getLinearUser,
  getLinearUsers,
} from "@in/server/libs/linear"
import { openaiClient } from "../libs/openAI"
import { Log } from "../utils/log"

type Context = {
  currentUserId: number
}

export const Input = Type.Object({
  text: Type.String(),
  messageId: Type.Number(),
  chatId: Type.Number(),
})

export const Response = Type.Object({
  link: Optional(Type.String()),
})

export const handler = async (
  input: Static<typeof Input>,
  { currentUserId }: Context,
): Promise<Static<typeof Response>> => {
  let { text, messageId, chatId } = input

  const labels = await getLinearIssueLabels({ userId: currentUserId })

  const linearUsers = await getLinearUsers({ userId: currentUserId })

  const message = `
You are an expert linguist creating concise task titles from messages in any language. Follow these steps:

1. TRANSLATION: If input is non-English, translate to English with maximum fidelity to:
   - Original intent and nuanced meaning
   - Cultural context and idiomatic expressions
   - Industry-specific terminology preservation
   Use professional translation standards (ISO 17100) for accuracy.

2. TITLE CREATION:
   a. Start with simple, human-action verb (e.g., "Fix", "Update", "Review")
   b. Maintain original message's key detail density
   c. Strictly avoid AI-related terms like "optimize", "leverage", "streamline"
   d. Should be sentence case.

3. LINEAR INTEGRATION:
   Labels: ${JSON.stringify(labels.labels, null, 2)}
   Users: ${JSON.stringify(linearUsers.users, null, 2)}
   Match using semantic similarity thresholds >0.7

Return JSON with this exact structure:
{
  "title": "<Translated/Original Text as Natural Task Title>",
  "description": "${text}", 
  "labelIds": ["<Matching-Label-ID>"] || [],
  "assigneeId": "<@Mention-Matched-ID>" || ""
}

Key Requirements:
-  Description must remain verbatim original text
-  Empty values allowed for missing matches
-  Title verb must be everyday action word
-  Never explain your reasoning
`

  const response = await openaiClient?.chat.completions.create({
    messages: [{ role: "user", content: message }],
    model: "gpt-4",
  })

  if (!response) {
    Log.shared.error("Failed to create OpenAI response")
    throw new Error("Failed to create OpenAI response")
  }
  try {
    const content = response.choices[0]?.message?.content

    if (!content) {
      Log.shared.error("Empty response from OpenAI")
      throw new Error("Empty response from OpenAI")
    }

    let jsonResponse
    try {
      jsonResponse = JSON.parse(content)
    } catch (parseError) {
      Log.shared.error("Failed to parse OpenAI response", { content, parseError })
      throw new Error("Invalid JSON response from OpenAI")
    }

    const link = await createIssueFunc({
      assigneeId: jsonResponse.assigneeId || undefined,
      title: jsonResponse.title,
      description: jsonResponse.description,
      messageId: messageId,
      chatId: chatId,
      labelIds: jsonResponse.labelIds,
      currentUserId: currentUserId,
    })

    return { link }
  } catch (error) {
    Log.shared.error("Failed to create issue")
    return { link: undefined }
  }
}

type CreateIssueProps = {
  assigneeId: string
  title: string
  description: string
  messageId: number
  chatId: number
  labelIds: string[]
  currentUserId: number
}

const createIssueFunc = async (props: CreateIssueProps): Promise<string | undefined> => {
  const team = await getLinearTeams({ userId: props.currentUserId })
  const teamIdValue = team?.id
  const organization = await getLinearOrg({ userId: props.currentUserId })
  const statuses = await getLinearIssueStatuses({ userId: props.currentUserId })
  const unstarded = statuses.workflowStates.filter((status: any) => status.type === "unstarted")

  try {
    let result = await createIssue({
      userId: props.currentUserId,
      title: props.title,
      description: props.description,
      teamId: teamIdValue ?? "",
      messageId: props.messageId,
      chatId: props.chatId,
      labelIds: props.labelIds,
      assigneeId: props.assigneeId || undefined,
      statusId: unstarded[0].id,
    })

    let link = generateIssueLink(result?.identifier ?? "", organization?.urlKey ?? "")
    return link
  } catch (error) {
    Log.shared.error("Failed to create Linear issue", { error })
  }
}
