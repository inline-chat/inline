import {
  OPENAI_AUTH_BASE_URL,
  OPENAI_CODEX_CLIENT_ID,
} from "@inline-chat/agent-chatgpt"
import {
  findActiveUserCodexConnection,
  markConnectionError,
  markConnectionUsed,
  updateConnectionCredential,
  type CodexCredential,
  type StoredCodexConnection,
} from "@in/server/modules/chatgpt/connections/connectionStore"
import { parseCredential } from "./codexDeviceAuth"
import { resolveCodexAuthIdentity } from "./codexIdentity"

const REFRESH_SKEW_MS = 2 * 60_000
const refreshes = new Map<number, Promise<StoredCodexConnection>>()

export async function resolveFreshUserCodexConnection(userId: number): Promise<StoredCodexConnection | undefined> {
  const connection = await findActiveUserCodexConnection(userId)
  if (!connection) {
    return undefined
  }

  if (!shouldRefresh(connection.credential)) {
    await markConnectionUsed(connection.row.id)
    return connection
  }

  const existing = refreshes.get(connection.row.id)
  if (existing) {
    return existing
  }

  const promise = refreshConnection(connection).finally(() => {
    refreshes.delete(connection.row.id)
  })
  refreshes.set(connection.row.id, promise)
  return promise
}

async function refreshConnection(connection: StoredCodexConnection): Promise<StoredCodexConnection> {
  try {
    const credential = await refreshCredential(connection.credential)
    const identity = resolveCodexAuthIdentity({ accessToken: credential.accessToken })
    await updateConnectionCredential({
      connectionId: connection.row.id,
      credential,
      identity,
    })
    await markConnectionUsed(connection.row.id)

    return {
      row: {
        ...connection.row,
        credentialCiphertext: connection.row.credentialCiphertext,
        expiresAt: credential.expiresAt ? new Date(credential.expiresAt) : null,
        status: "active",
        lastRefreshAt: new Date(),
        lastUsedAt: new Date(),
      },
      credential,
      identity,
    }
  } catch (error) {
    await markConnectionError({
      connectionId: connection.row.id,
      errorCode: "refresh_failed",
      errorMessage: error instanceof Error ? error.message : String(error),
    })
    throw error
  }
}

async function refreshCredential(credential: CodexCredential): Promise<CodexCredential> {
  const response = await fetch(`${OPENAI_AUTH_BASE_URL}/oauth/token`, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      originator: "inline",
      "User-Agent": "inline",
    },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: credential.refreshToken,
      client_id: OPENAI_CODEX_CLIENT_ID,
    }),
  })

  const bodyText = await response.text()
  if (!response.ok) {
    throw new Error(`OpenAI token refresh failed: HTTP ${response.status}`)
  }

  return parseCredential(bodyText)
}

function shouldRefresh(credential: CodexCredential): boolean {
  if (!credential.expiresAt) {
    return false
  }

  return credential.expiresAt - Date.now() <= REFRESH_SKEW_MS
}
