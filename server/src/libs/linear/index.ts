import { IntegrationsModel } from "@in/server/db/models/integrations"
import * as arctic from "arctic"
import type { Issue, Organization } from "@linear/sdk"
import { Log } from "@in/server/utils/log"

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
      : "http://127.0.0.1:8000/integrations/linear/callback",
  )
}

export const getLinearAuthUrl = (state: string) => {
  const scopes = ["read", "write"]
  const url = linearOauth?.createAuthorizationURL(state, scopes)
  if (!url) return { url }

  const authUrl = new URL(url.toString())
  // Use app-actor tokens so created issues appear as Inline (Linear OAuth actor authorization).
  // https://linear.app/developers/oauth-actor-authorization
  authUrl.searchParams.set("actor", "app")

  authUrl.searchParams.set("prompt", "consent")

  return { url: authUrl.toString() }
}

export const revokeLinearToken = async (input: {
  accessToken?: string | null
  refreshToken?: string | null
}): Promise<{ ok: boolean; status?: number }> => {
  const revokeUrl = "https://api.linear.app/oauth/revoke"

  const tryRevoke = async (init: RequestInit): Promise<{ ok: boolean; status?: number }> => {
    try {
      const response = await fetch(revokeUrl, init)
      if (response.status === 200 || response.status === 400) {
        // 400 can happen if token was already revoked.
        return { ok: true, status: response.status }
      }
      return { ok: false, status: response.status }
    } catch (error) {
      Log.shared.warn("Linear token revoke request failed", { error })
      return { ok: false }
    }
  }

  if (input.refreshToken) {
    const body = new URLSearchParams()
    body.set("refresh_token", input.refreshToken)

    const result = await tryRevoke({
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body,
    })

    if (result.ok) return result
  }

  if (input.accessToken) {
    const body = new URLSearchParams()
    body.set("access_token", input.accessToken)

    const result = await tryRevoke({
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        Authorization: `Bearer ${input.accessToken}`,
      },
      body,
    })

    if (result.ok) return result
  }

  return { ok: false }
}

export const queryLinear = async (input: { query: string; token: string; variables?: Record<string, unknown> }) => {
  return await fetch("https://api.linear.app/graphql", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${input.token}`,
    },
    body: JSON.stringify({
      query: input.query,
      variables: input.variables,
    }),
  })
}

const getLinearAccess = async (spaceId: number) => {
  if (isNaN(spaceId)) {
    throw new Error("Invalid spaceId")
  }
  return await IntegrationsModel.getAuthTokenWithSpaceId(spaceId, "linear")
}

interface CreateIssueParams {
  spaceId: number
  title: string
  description: string
  teamId: string
  messageId: number
  chatId: number
  labelIds?: string[]
  assigneeId?: string
}

const getLinearIssueLabels = async ({ spaceId }: { spaceId: number }) => {
  const { accessToken } = await getLinearAccess(spaceId)

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

const getLinearIssueStatuses = async ({ spaceId }: { spaceId: number }) => {
  const { accessToken } = await getLinearAccess(spaceId)

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

export type LinearTeam = { id: string; name: string; key: string }

const listLinearTeams = async ({ spaceId }: { spaceId: number }): Promise<LinearTeam[]> => {
  const { accessToken } = await getLinearAccess(spaceId)

  const response = await queryLinear({
    query: "{ teams { nodes { id name key } } }",
    token: accessToken,
  })

  const teamsData = await response.json()

  if (!teamsData.data) {
    throw new Error("Invalid response from Linear API")
  }

  return teamsData.data.teams.nodes
}

const getLinearTeams = async ({
  spaceId,
  requireSavedTeam = false,
}: {
  spaceId: number
  requireSavedTeam?: boolean
}): Promise<LinearTeam | undefined> => {
  const { linearTeamId } = await getLinearAccess(spaceId)
  const teams = await listLinearTeams({ spaceId })

  if (teams.length === 0) return undefined
  if (requireSavedTeam && !linearTeamId) return undefined
  if (linearTeamId) {
    const match = teams.find((team) => team.id === linearTeamId)
    if (match) return match
  }

  return requireSavedTeam ? undefined : teams[0]
}

const getLinearOrg = async ({ spaceId }: { spaceId: number }): Promise<Organization | undefined> => {
  const { accessToken } = await getLinearAccess(spaceId)

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

const getLinearUser = async ({ spaceId }: { spaceId: number }) => {
  const { accessToken } = await getLinearAccess(spaceId)

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

const getLinearUsers = async ({ spaceId }: { spaceId: number }) => {
  const { accessToken } = await getLinearAccess(spaceId)

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
  spaceId,
  title,
  description,
  teamId,
  labelIds = [],
  assigneeId,
}: CreateIssueParams): Promise<Issue | undefined> => {
  const { accessToken } = await getLinearAccess(spaceId)

  const response = await fetch("https://api.linear.app/graphql", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${accessToken}`,
    },
    body: JSON.stringify({
      query: `mutation IssueCreate($title: String!, $description: String!, $teamId: String!, $labelIds: [String!], $assigneeId: String) {
          issueCreate(input: {
            title: $title,
            description: $description,
            teamId: $teamId,
            labelIds: $labelIds,
            assigneeId: $assigneeId
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
      },
    }),
  })
  let result: any
  let rawText: string | undefined
  try {
    result = await response.json()
  } catch {
    rawText = await response.text().catch(() => undefined)
  }

  if (!result && rawText) {
    Log.shared.error("Linear API returned non-JSON response", {
      spaceId,
      teamId,
      httpStatus: response.status,
      labelIdsCount: labelIds.length,
      hasAssignee: Boolean(assigneeId),
      responsePreview: rawText.slice(0, 800),
    })
    throw new Error("Invalid response from Linear API")
  }

  if (!response.ok) {
    Log.shared.error("Linear API request failed", {
      spaceId,
      teamId,
      httpStatus: response.status,
      labelIdsCount: labelIds.length,
      hasAssignee: Boolean(assigneeId),
      responsePreview: rawText ? rawText.slice(0, 800) : undefined,
    })
    throw new Error("Linear API request failed")
  }

  const errorMessages: string[] | undefined = Array.isArray(result?.errors)
    ? result.errors.map((e: any) => String(e?.message ?? e)).slice(0, 10)
    : undefined

  const issueCreate = result?.data?.issueCreate
  const success = issueCreate?.success === true
  if (!success || !issueCreate?.issue) {
    Log.shared.error("Failed to create Linear issue", {
      spaceId,
      teamId,
      httpStatus: response.status,
      labelIdsCount: labelIds.length,
      hasAssignee: Boolean(assigneeId),
      errorMessages,
    })
    throw new Error(errorMessages?.[0] ?? "Failed to create Linear issue")
  }

  return issueCreate.issue
}

const deleteLinearIssue = async ({ spaceId, issueId }: { spaceId: number; issueId: string }) => {
  const { accessToken } = await getLinearAccess(spaceId)

  const response = await queryLinear({
    query: `mutation IssueDelete($id: String!) {
      issueDelete(id: $id) {
        success
      }
    }`,
    token: accessToken,
    variables: { id: issueId },
  })

  const result = await response.json()
  const success = result?.data?.issueDelete?.success === true

  if (!success) {
    Log.shared.warn("Failed to delete Linear issue", { spaceId, issueId, result })
  }

  return { success }
}

const generateIssueLink = (identifier: string, organizations: string) => {
  let link = `https://linear.app/${organizations}/issue/${identifier}`

  return link
}

export {
  getLinearIssueLabels,
  getLinearIssueStatuses,
  getLinearTeams,
  listLinearTeams,
  getLinearOrg,
  getLinearUser,
  createIssue,
  deleteLinearIssue,
  generateIssueLink,
  getLinearUsers,
}
