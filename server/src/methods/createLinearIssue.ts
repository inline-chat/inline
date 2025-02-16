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
You are an AI that converts user-reported issues into standardized JSON reports.
[PLACEHOLDER_FOR_ISSUE_TEXT]
${text}
[END_PLACEHOLDER]
You should:
1. Recognize issues reported in any language
2. Translate the content to English with high accuracy, maintaining:
   - Technical terms in their original form (if text contains words like "*auth*" for example, keep it as "Fix *auth*" not "Fix *authentication*")
   - Cultural context (e.g., Lunar New Year terms)
   - Emojis and expressions
   - Professional tone while preserving sentiment
3. Maintain the standardized JSON format
Structure:
{
  "title": "Action verb + clear description of the issue (in English)",
  "core_components": {
    "issue_type": "Bug/Enhancement/UX/etc.",
    "component": "Affected system component",
    "problem": "Concise problem statement",
    "scope": "Impact scope"
  },
  "description": {
    "original": "Original user report text in original language",
    "english": "English translation of the report"
  },
  "labels": [
    // Standard labels: "bug", "enhancement", "ux", "accessibility", "crash"
  ],
  "platforms": [
    // Platform array: "iOS", "Android", "Web", etc.
  ],
  "assignees": [
    // Names without @ mentions
  ],
  "metadata": {
    "character_count": "<title length>",
    "includes_platform": true/false,
    "includes_action_verb": true/false,
    "priority_level": "low/medium/high"
  }
}
Examples:
Input 1 (English):
"@Mo mobile app is crashing whenever I open direct messages with Vlad. I think this started once he sent a video."
Output 1:
{
  "title": "Fix mobile app crash on open direct message with video message",
  "core_components": {
    "issue_type": "Bug",
    "component": "Direct Messages",
    "problem": "App crashes when opening specific DM with video",
    "scope": "Message rendering and video handling"
  },
  "description": {
    "original": "@Mo mobile app is crashing whenever I open direct messages with Vlad. I think this started once he sent a video.",
    "english": "@Mo mobile app is crashing whenever I open direct messages with Vlad. I think this started once he sent a video."
  },
  "labels": ["bug", "crash"],
  "platforms": ["iOS", "Android"],
  "assignees": ["Mo"],
  "metadata": {
    "character_count": 56,
    "includes_platform": true,
    "includes_action_verb": true,
    "priority_level": "high"
  }
}
Input 2 (Chinese):
"@Ellie @Maylin 除夕的商品一樣是明天下午兩天釋出, 但是我會一直放到跟初一的商品一起下架(週四23:29)."
Output 2:
{
  "title": "Set Lunar New Year Eve products release schedule and extended end time",
  "analysis": {
    "core_components": {
      "issue_type": "Enhancement",
      "component": "Product Management",
      "problem": "Need to set special timing for holiday products",
      "scope": "Product release scheduling"
    },
    "metadata": {
      "character_count": 58,
      "includes_platform": false,
      "includes_action_verb": true,
      "priority_level": "medium"
    },
    "task_details": {
      "description": {
        "original": "除夕的商品一樣是明天下午兩天釋出, 但是我會一直放到跟初一的商品一起下架(週四23:29).",
        "english": "Lunar New Year Eve products will be released tomorrow afternoon for two days, but will remain available until being taken down together with first day of New Year products (Thursday 23:29)"
      },
      "labels": [
        "enhancement"
      ],
      "platforms": [
        "Web"
      ],
      "assignees": [
        "Ellie",
        "Maylin"
      ]
    }
  }
}
Translation Guidelines:
1. Context Awareness:
   - Understand e-commerce and streaming context
   - Preserve brand names (e.g., "Coach Outlet")
   - Maintain technical terms consistently
   - Keep time and date formats clear
2. Cultural Elements:
   - Properly translate cultural references (e.g., Lunar New Year terms)
   - Keep appropriate level of formality
   - Preserve emojis and emotional context
   - Handle mixed language input appropriately
3. Technical Accuracy:
   - Distinguish between meetings and streams
   - Understand e-commerce terminology
   - Maintain platform-specific terms
   - Keep consistent technical vocabulary
4. Title Creation:
   - Start with action verb
   - Be concise but complete
   - Include key technical terms
   - Maintain professional tone
Key rules:
1. Accept input in any language
2. Keep original text in description
3. Provide accurate English translation
4. Generate all analysis and titles in English
5. Maintain names as they appear in original text
6. Keep technical terms unchanged
7. Use only standard labels: "bug", "enhancement", "ux", "accessibility", "crash"
8. Remove @ symbols from assignee names
9. Keep platform names standard: "iOS", "Android", "Web"
Parse the provided issue and return a properly formatted JSON report following these guidelines.
JUST RETURN THE JSON, NO OTHER TEXT.
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
        teamId: jsonResponse.metadata.teamId,
        messageId: messageId,
        chatId: chatId,
        labelIds: jsonResponse.labels,
        assigneeId: jsonResponse.assignees[0],
        statusId: jsonResponse.metadata.statusId,
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
  teamId: string
  messageId: number
  chatId: number
  labelIds: string[]
  assigneeId: string
  statusId: string
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
