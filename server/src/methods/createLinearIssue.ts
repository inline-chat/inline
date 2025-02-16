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
} from "@in/server/libs/linear"
import { openaiClient } from "../libs/openAI"

type Context = {
  currentUserId: number
}

export const Input = Type.Object({
  text: Type.String(),
  spaceId: Type.Number(),
  messageId: Type.Number(),
  chatId: Type.Number(),
})

export const Response = Type.Undefined()

export const handler = async (
  input: Static<typeof Input>,
  { currentUserId }: Context,
): Promise<Static<typeof Response>> => {
  const { text, spaceId, messageId, chatId } = input
  const space = await getSpace(spaceId)

  const message = `
  Convert user reports to JSON tickets with this structure:
  [input text]
  ${text}
  [end input text]
  {
    "title": <"Specific action + target element">,
    "description": {
      "original": <"Raw input">,
      "english": <"Cleaned translation">
    },
    "labels": [ // "bug", "enhancement", "ux", "accessibility", "crash" ,"feature", or some other label like these],
    "platforms": ["iOS", "Android", "Web"],
    "assignees": [ // "Names from input"]
  }
  
  [Title Rules]
  1. Required verbs:
     - Add "[Feature]"
     - Fix "[UI/Breakage]" 
     - Increase/Decrease "[Metric]"
     - Make "[Element]" [bigger/smaller/clearer]
     - Move "[Component]"
     - Change "[Behavior]"
  - Or common and human like verbs like the top ones
  
  2. Requirements:
     - Include numbers when specified ("Increase timeout to 30s")
     - Mention integrated services ("Add Zoom to calendar")
     - Keep under 60 characters
     - Use specific terms like "increase height" instead of general terms like "make taller."
  
  
  [Examples]
  Input: "@Mo will do→Notion broken #noor-bugs"
  Output:
  {
    "title": "Add 'Will do' to Notion issue creation",
    "description": {
      "original": "@Mo it would be useful to have will do actually work here. instead Isaac has to reply to Matthew, and engage the Notion issue creator #noor-bugs",
      "english": "Implement 'Will do' functionality for automatic Notion issue creation instead of manual replies"
    },
    "labels": ["enhancement"],
    "platforms": ["Web"],
    "assignees": ["Mo"]
  }
  
  Input: "Text in settings too damn small"
  Output:
  {
    "title": "Make settings text size 20% larger",
    "description": {
      "original": "Text in settings too damn small",
      "english": "Increase settings interface text size for better readability"
    },
    "labels": ["ux"],
    "platforms": ["Android"],
    "assignees": []
  }
  
  [Processing Rules]
  1. Convert implied requests to explicit metrics
  2. Remove hashtags/internal codes
  3. Keep brand names in titles
  4. Use exact numbers from input
  5. Never add new fields
  
  Return ONLY JSON, no other text.  
  `

  const response = await openaiClient?.chat.completions.create({
    messages: [{ role: "user", content: message }],
    model: "gpt-4o",
  })

  if (!response) {
    throw new Error("Failed to create OpenAI response")
  }

  try {
    const rawResponse = response.choices[0]?.message?.content || "{}"
    const cleanJson = rawResponse.replace(/```json|```/g, "")
    const jsonResponse = JSON.parse(cleanJson)

    const matchingUsers =
      jsonResponse.assignees
        ?.map((assignee: string) => {
          const matchedUser = space?.members.find(
            (member) =>
              member.user.firstName?.toLowerCase() === assignee.toLowerCase() ||
              member.user.firstName?.toLowerCase().startsWith(assignee.toLowerCase()),
          )
          return matchedUser?.user || null
        })
        .filter(Boolean) || []

    for (const user of matchingUsers) {
      await createIssueFunc({
        userId: user.id,
        title: jsonResponse.title,
        description: jsonResponse.description.original,
        messageId: messageId,
        chatId: chatId,
        labelIds: jsonResponse.labels,
      })
    }
  } catch (error) {
    console.error("Error parsing JSON response:", error)
  }
}

const getSpace = async (spaceId: number) => {
  const space = await db.query.spaces.findFirst({
    where: eq(spaces.id, spaceId),
    with: {
      members: {
        with: {
          user: true,
        },
      },
    },
  })

  return space
}

type CreateIssueProps = {
  userId: number
  title: string
  description: string
  messageId: number
  chatId: number
  labelIds: string[]
}

const createIssueFunc = async (props: CreateIssueProps) => {
  const teamId = await getLinearTeams({ userId: props.userId })
  const teamIdValue = teamId.teams.teams.nodes[0].id

  const labels = await getLinearIssueLabels({ userId: props.userId })
  const matchingLabels = labels.labels.filter((label: any) => props.labelIds.includes(label.name.toLowerCase()))

  const linearUser = await getLinearUser({ userId: props.userId })
  const statuses = await getLinearIssueStatuses({ userId: props.userId })
  const unstarded = statuses.workflowStates.filter((status: any) => status.type === "unstarted")

  try {
    await createIssue({
      userId: props.userId,
      title: props.title,
      description: props.description,
      teamId: teamIdValue,
      messageId: props.messageId,
      chatId: props.chatId,
      labelIds: matchingLabels.map((l: any) => l.id),
      assigneeId: linearUser.user.id,
      statusId: unstarded[0].id,
    })
  } catch (error) {
    console.error("Error creating Linear issue:", error)
  }
}
