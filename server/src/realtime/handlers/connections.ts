import {
  OpenAICodexDeviceAuthStatus,
  type ConnectionsDisconnectInput,
  type ConnectionsDisconnectResult,
  type ConnectionsListInput,
  type ConnectionsListResult,
  type OpenAICodexPollDeviceAuthInput,
  type OpenAICodexPollDeviceAuthResult,
  type OpenAICodexStartDeviceAuthInput,
  type OpenAICodexStartDeviceAuthResult,
} from "@inline-chat/protocol/core"
import type { HandlerContext } from "@in/server/realtime/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import {
  decodeInputScope,
  disconnectOwnedConnection,
  listCurrentUserConnections,
  saveCodexConnection,
} from "@in/server/modules/chatgpt/connections/connectionStore"
import { startCodexDeviceAuth, pollCodexDeviceAuth } from "@in/server/modules/chatgpt/auth/codexDeviceAuth"

export async function connectionsListHandler(
  _input: ConnectionsListInput,
  context: HandlerContext,
): Promise<ConnectionsListResult> {
  return {
    connections: await listCurrentUserConnections(context.userId),
  }
}

export async function openaiCodexStartDeviceAuthHandler(
  input: OpenAICodexStartDeviceAuthInput,
  context: HandlerContext,
): Promise<OpenAICodexStartDeviceAuthResult> {
  const scope = decodeInputScope(input.scope, context.userId)
  if (!scope || scope.type !== "user" || scope.userId !== context.userId) {
    throw RealtimeRpcError.BadRequest()
  }

  const auth = await startCodexDeviceAuth({
    ownerUserId: context.userId,
    scope,
  })

  return {
    auth: {
      pendingId: auth.pendingId,
      verificationUrl: auth.verificationUrl,
      userCode: auth.userCode,
      expiresAt: BigInt(auth.expiresAt),
      intervalSeconds: auth.intervalSeconds,
    },
  }
}

export async function openaiCodexPollDeviceAuthHandler(
  input: OpenAICodexPollDeviceAuthInput,
  context: HandlerContext,
): Promise<OpenAICodexPollDeviceAuthResult> {
  if (!input.pendingId.trim()) {
    throw RealtimeRpcError.BadRequest()
  }

  const result = await pollCodexDeviceAuth({
    ownerUserId: context.userId,
    pendingId: input.pendingId,
  })

  switch (result.status) {
    case "pending":
      return { status: OpenAICodexDeviceAuthStatus.OPENAI_CODEX_DEVICE_AUTH_PENDING }
    case "expired":
      return { status: OpenAICodexDeviceAuthStatus.OPENAI_CODEX_DEVICE_AUTH_EXPIRED }
    case "error":
      return {
        status: OpenAICodexDeviceAuthStatus.OPENAI_CODEX_DEVICE_AUTH_ERROR,
        errorCode: result.errorCode,
        errorMessage: result.errorMessage,
      }
    case "connected": {
      if (result.scope.type !== "user" || result.scope.userId !== context.userId) {
        throw RealtimeRpcError.BadRequest()
      }

      const connection = await saveCodexConnection({
        scope: result.scope,
        connectedByUserId: context.userId,
        credential: result.credential,
        identity: result.identity,
      })

      return {
        status: OpenAICodexDeviceAuthStatus.OPENAI_CODEX_DEVICE_AUTH_CONNECTED,
        connection,
      }
    }
  }
}

export async function connectionsDisconnectHandler(
  input: ConnectionsDisconnectInput,
  context: HandlerContext,
): Promise<ConnectionsDisconnectResult> {
  const connectionId = Number(input.connectionId)
  if (!Number.isSafeInteger(connectionId) || connectionId <= 0) {
    throw RealtimeRpcError.BadRequest()
  }

  return {
    disconnected: await disconnectOwnedConnection({
      connectionId,
      userId: context.userId,
    }),
  }
}
