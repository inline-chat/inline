import { IntegrationsModel } from "@in/server/db/models/integrations"
import * as arctic from "arctic"

// export const linearOauth = new arctic.Linear(
//   process.env.LINEAR_CLIENT_ID,
//   process.env.LINEAR_CLIENT_SECRET,
//   process.env.NODE_ENV === "production" ? process.env.LINEAR_REDIRECT_URI : "https://api.inline.chat/",
// )

export let linearOauth: arctic.Linear | undefined

if (process.env.LINEAR_CLIENT_ID && process.env.LINEAR_CLIENT_SECRET) {
  linearOauth = new arctic.Linear(
    process.env.LINEAR_CLIENT_ID,
    process.env.LINEAR_CLIENT_SECRET,
    process.env.NODE_ENV === "production" ? process.env.LINEAR_REDIRECT_URI : "https://api.inline.chat/",
  )
}

export const getLinearAuthUrl = (state: string) => {
  const scopes = ["read", "write"]
  const url = linearOauth?.createAuthorizationURL(state, scopes)

  return { url }
}

export const queryLinear = async (input: { query: string; token: string }) => {
  return await fetch("https://api.linear.app/graphql", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${input.token}`,
    },
    body: JSON.stringify({
      query: input.query,
    }),
  })
}

interface CreateIssueParams {
  userId: number
  title: string
  description: string
  teamId: string
  messageId: number
  chatId: number
  labelIds?: string[]
  assigneeId?: string
  statusId?: string
}

const getLinearIssueLabels = async ({ userId }: { userId: number }) => {
  if (isNaN(userId)) {
    throw new Error("Invalid userId")
  }

  const { accessToken } = await IntegrationsModel.getWithUserId(userId)

  const response = await queryLinear({
    query: "{ issueLabels { nodes { name createdAt id } } }",
    token: accessToken,
  })

  const labels = await response.json()

  if (!labels.data?.issueLabels) {
    throw new Error("Invalid response from Linear API")
  }

  return {
    labels: labels.data.issueLabels.nodes,
  }
}

const getLinearIssueStatuses = async ({ userId }: { userId: number }) => {
  if (isNaN(userId)) {
    throw new Error("Invalid userId")
  }

  const { accessToken } = await IntegrationsModel.getWithUserId(userId)

  const response = await queryLinear({
    query: `{ workflowStates { nodes { id color type position description createdAt updatedAt } } }`,
    token: accessToken,
  })

  const workflowStates = await response.json()

  if (!workflowStates.data?.workflowStates) {
    throw new Error("Invalid response from Linear API")
  }

  return {
    workflowStates: workflowStates.data.workflowStates.nodes,
  }
}

const getLinearTeams = async ({ userId }: { userId: number }) => {
  if (isNaN(userId)) {
    throw new Error("Invalid userId")
  }

  const { accessToken } = await IntegrationsModel.getWithUserId(userId)

  const response = await queryLinear({
    query: "{ teams { nodes { id name } } }",
    token: accessToken,
  })

  const teamsData = await response.json()

  if (!teamsData.data) {
    throw new Error("Invalid response from Linear API")
  }

  return {
    teams: teamsData.data,
  }
}

const getLinearUser = async ({ userId }: { userId: number }) => {
  if (isNaN(userId)) {
    throw new Error("Invalid userId")
  }

  const { accessToken } = await IntegrationsModel.getWithUserId(userId)

  const response = await fetch("https://api.linear.app/graphql", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${accessToken}`,
    },
    body: JSON.stringify({
      query: "{ viewer { id name email } }",
    }),
  })

  const userData = await response.json()

  if (!userData.data?.viewer) {
    throw new Error("Invalid response from Linear API")
  }

  return {
    user: userData.data.viewer,
  }
}

const createIssue = async ({
  userId,
  title,
  description,
  teamId,
  messageId,
  chatId,
  labelIds = [],
  assigneeId,
  statusId,
}: CreateIssueParams) => {
  if (isNaN(userId)) {
    return {
      ok: false,
      error: "Invalid userId",
    }
  }

  const { accessToken } = await IntegrationsModel.getWithUserId(userId)

  const response = await fetch("https://api.linear.app/graphql", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${accessToken}`,
    },
    body: JSON.stringify({
      query: `mutation IssueCreate($title: String!, $description: String!, $teamId: String!, $labelIds: [String!], $assigneeId: String, $statusId: String) {
          issueCreate(input: { 
            title: $title, 
            description: $description, 
            teamId: $teamId,
            labelIds: $labelIds,
            assigneeId: $assigneeId,
            stateId: $statusId
          }) {
            success
            issue {
              id
              title
            }
          }
        }`,
      variables: {
        title,
        description,
        teamId,
        labelIds,
        assigneeId,
        statusId,
      },
    }),
  })

  const data = await response.json()

  if (!data.data?.issueCreate) {
    return {
      ok: false,
      error: "Failed to create Linear issue",
    }
  }

  return {
    ok: true,
    issue: data.data.issueCreate.issue,
  }
}

export { getLinearIssueLabels, getLinearIssueStatuses, getLinearTeams, getLinearUser, createIssue }
