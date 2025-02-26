import { Optional, Type, type Static } from "@sinclair/typebox"
import { eq } from "drizzle-orm"
import OpenAI from "openai"
import { spaces, users } from "../db/schema"
import { db } from "../db"
import { z } from "zod"
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
import { zodResponseFormat } from "openai/helpers/zod.mjs"

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
  You are a product manager creating tasks for engineers, designers, and other startup roles from messages in their Slack messages. Follow these steps:
  
  1. INPUT MESSAGE: "${text}"
  
  2. TITLE CREATION RULES:
     a. Use common task title verbs like "Fix", "Update", "Add", "Remove"
     b. Use sentence case
     c. Keep it concise and to the point explaining the task/feature/fix mentioned in the message.
     d. PROHIBITED: AI jargon ("optimize", "leverage", "streamline", "capability") use simple and decriptive words often used in project management software or tasks in a software company. Match their tone, no need to formalize it. Keep technical jargon user mentioned.
     g. Be careful to not count every word as a task.
     h. Make sure you are not returning the sentence with it's own verb without making it task title and adding the action verb in the beginning of the title eg.
     Message: edit message 
     title should be "Add edit message" no "Edit message" 

     TITLE FORMAT EXAMPLES:
     Message: "Dena please fix open DM chats on notification click, it's working randomly for me."
     Title: "Fix random DM open on notification click"
  
     Message: "@Mo this message failed to translate. It was a long message from a zh user"
     Title: "Fix translation bug for long ZH messages"
  
     Message: "todo: - video upload"
     Title: "Add video upload"
  
  3. ASSIGNEE DETECTION:
     - Trigger on exact @ mentions
     - Match against provided user list
     Users: ${JSON.stringify(linearUsers.users, null, 2)}
  
  4. LABEL MATCHING:
     - Use semantic similarity (threshold >0.7)
     - Match against provided labels
     Labels: ${JSON.stringify(labels.labels, null, 2)}
  
  OUTPUT FORMAT:
  {
    "title": "<Task Title>",
    "labelIds": ["<Matching-Label-ID>"] || [],
    "assigneeId": "<Mentioned-User-ID>" || ""
  }
  `

  // const message = `
  // You are an expert linguist creating accurate task titles from messages in any language. Follow these steps:
  // the message is : ${text}.
  // 2. TITLE CREATION:
  //    a. Start with simple, human-action verb (e.g., "Fix", "Update", "Add")
  //    b. Maintain original message's key detail density
  //    c. Strictly avoid AI-related terms like "optimize", "leverage", "streamline"
  //    d. Should be sentence case.
  //     e. Make sure you added the core part (what is the issue or feature to add) and if it's an issue how this issue was exactly created in title.
  //       eg. Message: Dena please fix open DM chats on notification click, it's working randomly for me.
  //       Title: Fix open DM on notifications click
  //       Message2: @Mo this message failed to translate. It was a long message from a zh user
  //       Title2: Fix translation failure on long zh messages
  //       Message3: handle video messages
  //       Title3: Add video message
  //     f. if the text was like this: Load more & paginate -  2h. or like this: Load more & paginate (2h) ignore the - 2h / (2h) part in title generation

  // 3. LINEAR INTEGRATION:
  //    Labels: ${JSON.stringify(labels.labels, null, 2)}
  //    Users: ${JSON.stringify(linearUsers.users, null, 2)}
  //    Match using semantic similarity thresholds >0.7

  // Return JSON with this exact structure:
  // {
  //   "title": "<Translated/Original Text as Natural Task Title>",
  //   "description": "${text}",
  //   "labelIds": ["<Matching-Label-ID>"] || [],
  //   "assigneeId": "<@Mention-Matched-ID>" || null
  // }

  // Key Requirements:
  // -  Description must remain verbatim original text
  // -  Empty values allowed for missing matches
  // -  Title verb must be everyday action word
  // -  Never explain your reasoning
  // `

  const ResponseSchema = z.object({
    title: z.string(),
    labelIds: z.array(z.string()),
    assigneeId: z.string().optional(),
  })

  const response = await openaiClient?.chat.completions.create({
    messages: [
      {
        role: "user",
        content: message,
      },
    ],
    model: "gpt-4o-2024-11-20",
    response_format: zodResponseFormat(ResponseSchema, "task"),
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
  try {
    const [team, organization, statuses] = await Promise.all([
      getLinearTeams({ userId: props.currentUserId }),
      getLinearOrg({ userId: props.currentUserId }),
      getLinearIssueStatuses({ userId: props.currentUserId }),
    ])

    const teamIdValue = team?.id
    const unstarded = statuses.workflowStates.filter((status: any) => status.type === "unstarted")

    const result = await createIssue({
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

    return generateIssueLink(result?.identifier ?? "", organization?.urlKey ?? "")
  } catch (error) {
    Log.shared.error("Failed to create Linear issue", { error })
    return undefined
  }
}
