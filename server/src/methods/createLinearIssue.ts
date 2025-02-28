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
import { anthropic } from "../libs/anthropic"

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

  // const message = `
  // You are a product manager creating tasks for engineers, designers, and other startup roles from messages in their Slack messages. Follow these steps:

  // 1. INPUT MESSAGE: "${text}"

  // 2. TITLE CREATION RULES:
  //    a. Use common task title verbs like "Fix", "Update", "Add", "Remove"
  //    b. Use sentence case
  //    c. Keep it concise and to the point explaining the task/feature/fix mentioned in the message.
  //    d. PROHIBITED: AI jargon ("optimize", "leverage", "streamline", "capability") use simple and decriptive words often used in project management software or tasks in a software company. Match their tone, no need to formalize it. Keep technical jargon user mentioned.
  //    g. Be careful to not count every word as a task.
  //    h. Make sure you are not returning the sentence with it's own verb without making it task title and adding the action verb in the beginning of the title eg.
  //    Message: edit message
  //    title should be "Add edit message" no "Edit message"

  //    TITLE FORMAT EXAMPLES:
  //    Message: "Dena please fix open DM chats on notification click, it's working randomly for me."
  //    Title: "Fix random DM open on notification click"

  //    Message: "@Mo this message failed to translate. It was a long message from a zh user"
  //    Title: "Fix translation bug for long ZH messages"

  //    Message: "todo: - video upload"
  //    Title: "Add video upload"

  // 3. ASSIGNEE DETECTION:
  //    - Trigger on exact @ mentions
  //    - Match against provided user list
  //    Users: ${JSON.stringify(linearUsers.users, null, 2)}

  // 4. LABEL MATCHING:
  //    - Use semantic similarity (threshold >0.7)
  //    - Match against provided labels
  //    Labels: ${JSON.stringify(labels.labels, null, 2)}

  // OUTPUT FORMAT:
  // {
  //   "title": "<Task Title>",
  //   "labelIds": ["<Matching-Label-ID>"] || [],
  //   "assigneeId": "<Mentioned-User-ID>" || ""
  // }
  // `

  const ResponseSchema = z.object({
    title: z.string(),
    labelIds: z.array(z.string()),
    assigneeId: z.string().optional(),
  })

  // const response = await openaiClient?.chat.completions.create({
  //   messages: [
  //     {
  //       role: "user",
  //       content: message,
  //     },
  //   ],
  //   model: "gpt-4o-2024-11-20",
  //   response_format: zodResponseFormat(ResponseSchema, "task"),
  // })

  // if (!response) {
  //   Log.shared.error("Failed to create OpenAI response")
  //   throw new Error("Failed to create OpenAI response")
  // }

  const message = `You are a task creation assistant for a startup. Your job is to create tasks from Slack messages, following specific rules for title creation, assignee detection, and label matching. Here's how to proceed:
  First, here's the message you'll be working with:
  <message>
  ${text}
  </message>
  Here are the available users and labels:
  <users>
  ${JSON.stringify(linearUsers.users, null, 2)}
  </users>
  <labels>
  ${JSON.stringify(labels.labels, null, 2)}
  </labels>
  Now, follow these steps to create a task:
  1. Create a task title:
     a. Use common task title verbs like "Fix", "Update", "Add", "Remove" at the beginning.
     b. Use sentence case.
     c. Keep it concise and to the point, explaining the task/feature/fix mentioned in the message.
     d. Avoid AI jargon like "optimize", "leverage", "streamline", "capability". Use simple and descriptive words often used in project management software or tasks in a software company. Match the tone of the original message without formalizing it. Keep any technical jargon the user mentioned.
     e. Be careful not to count every word as a task.
     f. Make sure you're not returning the sentence with its own verb without making it a task title. For example, if the message is "edit message", the title should be "Add edit message" not "Edit message".
  2. Detect the assignee:
     - Look for exact @ mentions in the message.
     - Match the mentioned name against the provided user list.
     - If a match is found, use the corresponding user ID.
  3. Match labels:
     - Use semantic similarity with a threshold greater than 0.7.
     - Compare the content of the message with the provided labels.
     - If a match is found, use the corresponding label ID.
  4. Generate the output in the following JSON format:
     {
       "title": "<Task Title>",
       "labelIds": ["<Matching-Label-ID>"] || [],
       "assigneeId": "<Mentioned-User-ID>" || ""
     }
  Please just return the JSON and avoid returning your reasoning. Avoid returning <scratchpad> and what are between them just return <output> and remove <output> tag around the json output.
  Now, process the given message and generate the task output. First, think through your approach in a <scratchpad> section. Then, provide your final output in an <output> section.
  `

  const msg = await anthropic.messages.create({
    model: "claude-3-7-sonnet-20250219",
    max_tokens: 20000,
    temperature: 1,
    messages: [
      {
        role: "user",
        content: [
          {
            type: "text",
            text: '<examples>\n<example>\n<MESSAGE>\n@Mo this message failed to translate. It was a long message from a zh user\n</MESSAGE>\n<USERS>\nMo - Dena\n</USERS>\n<LABELS>\nBug, Feature, iOS, macOS\n</LABELS>\n<ideal_output>\n{\n  "title": "Fix translation bug for long zh message",\n  "labelIds": ["Bug"],\n  "assigneeId": "Dena"\n}\n</ideal_output>\n</example>\n<example>\n<MESSAGE>\n@Mo  mobile app is crashing whenever I open direct messages with Vlad. I think this started once he sent a video. Can you assist pls \n</MESSAGE>\n<USERS>\nMo - Dena\n</USERS>\n<LABELS>\nBug, Feature, iOS, macOS\n</LABELS>\n<ideal_output>\n{\n  "title": "Fix mobile app crash when opening direct messages with videos",\n  "labelIds": ["Bug"],\n  "assigneeId": "Mo"\n}\n</ideal_output>\n</example>\n<example>\n<MESSAGE>\n@Mo  mobile app is crashing whenever I open direct messages with Vlad. I think this started once he sent a video. Can you assist pls \n</MESSAGE>\n<USERS>\nMo - Dena\n</USERS>\n<LABELS>\nBug, Feature, iOS, macOS\n</LABELS>\n<ideal_output>\n{\n  "title": "Fix mobile app crash when opening direct messages with videos",\n  "labelIds": ["Bug"],\n  "assigneeId": "Mo"\n}\n</ideal_output>\n</example>\n<example>\n<MESSAGE>\n@Mo this message failed to translate. It was a long message from a zh user\n</MESSAGE>\n<USERS>\nMo - Dena\n</USERS>\n<LABELS>\nBug, Feature, iOS, macOS\n</LABELS>\n<ideal_output>\n{\n  "title": "Fix translation bug for long zh message",\n  "labelIds": ["Bug"],\n  "assigneeId": "Mo"\n}\n</ideal_output>\n</example>\n</examples>',
          },
          {
            type: "text",
            text: message,
          },
        ],
      },
    ],
  })

  try {
    if (!msg.content[0] || msg.content[0].type !== "text") {
      Log.shared.error("Unexpected response format from Anthropic")
      throw new Error("Invalid response format from Anthropic")
    }

    const responseText = (msg.content[0] as { type: "text"; text: string }).text

    const jsonMatch = responseText.match(/```json\n([\s\S]*?)\n```/)

    if (!jsonMatch || !jsonMatch[1]) {
      Log.shared.error("Failed to extract JSON from Anthropic response")
      throw new Error("Invalid response format from Anthropic")
    }

    const jsonResponse = JSON.parse(jsonMatch[1])

    const link = await createIssueFunc({
      assigneeId: jsonResponse.assigneeId || undefined,
      title: jsonResponse.title,
      description: text,
      messageId: messageId,
      chatId: chatId,
      labelIds: jsonResponse.labelIds,
      currentUserId: currentUserId,
    })

    return { link }
  } catch (error) {
    Log.shared.error("Failed to create issue", { error })
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
