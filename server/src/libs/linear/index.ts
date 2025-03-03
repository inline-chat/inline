import { IntegrationsModel } from "@in/server/db/models/integrations"
import * as arctic from "arctic"
import type { Issue, Organization, Team } from "@linear/sdk"
import { LinearClient, LinearSdk } from "@linear/sdk"
import { Log } from "@in/server/utils/log"
import { error } from "elysia"

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
    process.env.NODE_ENV === "production"
      ? "https://api.inline.chat/integrations/linear/callback"
      : "https://api.inline.chat/",
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

const getLinearTeams = async ({ userId }: { userId: number }): Promise<Team | undefined> => {
  if (isNaN(userId)) {
    throw new Error("Invalid userId")
  }

  const { accessToken } = await IntegrationsModel.getWithUserId(userId)

  const response = await queryLinear({
    query: "{ teams { nodes { id name key } } }",
    token: accessToken,
  })

  const teamsData = await response.json()

  if (!teamsData.data) {
    throw new Error("Invalid response from Linear API")
  }

  return teamsData.data.teams.nodes[0]
}

const getLinearOrg = async ({ userId }: { userId: number }): Promise<Organization | undefined> => {
  if (isNaN(userId)) {
    throw new Error("Invalid userId")
  }

  const { accessToken } = await IntegrationsModel.getWithUserId(userId)

  const response = await queryLinear({
    query: "{ organization{ id name urlKey} }",
    token: accessToken,
  })

  const orgData = await response.json()

  if (!orgData.data) {
    throw new Error("Invalid response from Linear API")
  }

  return orgData.data.organization
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

const getLinearUsers = async ({ userId }: { userId: number }) => {
  if (isNaN(userId)) {
    throw new Error("Invalid userId")
  }

  const { accessToken } = await IntegrationsModel.getWithUserId(userId)

  const response = await queryLinear({
    query: `{ users { nodes { id name email } } }`,
    token: accessToken,
  })

  const usersData = await response.json()

  if (!usersData.data?.users) {
    throw new Error("Invalid response from Linear API")
  }

  return {
    users: usersData.data.users.nodes,
  }
}

const createIssue = async ({
  userId,
  title,
  description,
  teamId,
  labelIds = [],
  assigneeId,
  statusId,
}: CreateIssueParams): Promise<Issue | undefined> => {
  if (isNaN(userId)) {
    Log.shared.error("Failed to create issue - userId is invalid")
    throw new Error("Failed to create issue - userId is invalid")
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
              identifier
              number
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
  const result = await response.json()

  if (!result.data.issueCreate.success) {
    Log.shared.error("Failed to create issue", error)
    throw new Error("Failed to create issue")
  }

  return result.data.issueCreate.issue
}

const generateIssueLink = (identifier: string, organizations: string) => {
  let link = `https://linear.app/${organizations}/issue/${identifier}`

  return link
}

export {
  getLinearIssueLabels,
  getLinearIssueStatuses,
  getLinearTeams,
  getLinearOrg,
  getLinearUser,
  createIssue,
  generateIssueLink,
  getLinearUsers,
}
