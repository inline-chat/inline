import { Type, type Static } from "@sinclair/typebox"
import { eq } from "drizzle-orm"
import OpenAI from "openai"
import { spaces } from "../db/schema"
import { db } from "../db"
import {
  createIssue,
  getLinearIssueLabels,
  getLinearIssueStatuses,
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

export const Response = Type.Undefined()

export const handler = async (
  input: Static<typeof Input>,
  { currentUserId }: Context,
): Promise<Static<typeof Response>> => {
  let { text, messageId, chatId } = input

  const labels = await getLinearIssueLabels({ userId: currentUserId })

  const linearUsers = await getLinearUsers({ userId: currentUserId })

  const message = `
You are an expert in creating task titles from messages in all languages. You make the best titles in the world, and your focus is on not using AI buzzwords. Here is the message text: ${text}. I use Linear for task management. Here are my issue labels:
${JSON.stringify(labels.labels, null, 2)}
Find the related ones to the message and return them. Find the assignee by considering who the issue or the task is reported to or who is mentioned with @ in the message and match them with Linear users, then return the matched userId. Linear users:
${JSON.stringify(linearUsers.users, null, 2)}
Please return a simple JSON like this with the results: 
{
  "title": "<task title you made in sentence case>",
  "description": "<the message I gave you as input>",
  "labelIds": "<the ID of labels you matched with Linear labels>",
  "assigneeId": "<The id you found for who the issue is reported to from Linear users>"
}
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

    await createIssueFunc({
      assigneeId: jsonResponse.assigneeId,
      title: jsonResponse.title,
      description: jsonResponse.description,
      messageId: messageId,
      chatId: chatId,
      labelIds: jsonResponse.labelIds,
      currentUserId: currentUserId,
    })
  } catch {
    Log.shared.error("Failed to create issue")
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

const createIssueFunc = async (props: CreateIssueProps) => {
  const teamId = await getLinearTeams({ userId: props.currentUserId })
  const teamIdValue = teamId.teams.teams.nodes[0].id

  const statuses = await getLinearIssueStatuses({ userId: props.currentUserId })
  const unstarded = statuses.workflowStates.filter((status: any) => status.type === "unstarted")

  try {
    await createIssue({
      userId: props.currentUserId,
      title: props.title,
      description: props.description,
      teamId: teamIdValue,
      messageId: props.messageId,
      chatId: props.chatId,
      labelIds: props.labelIds,
      assigneeId: props.assigneeId,
      statusId: unstarded[0].id,
    })
  } catch (error) {
    Log.shared.error("Failed to create Linear issue", { error })
  }
}
