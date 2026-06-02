import { db } from "@in/server/db"
import { chats, integrations } from "@in/server/db/schema"
import { decrypt } from "@in/server/modules/encryption/encryption"
import { Log } from "@in/server/utils/log"
import { and, eq, isNull } from "drizzle-orm"
import type {
  PreviewAuthInput,
  PreviewAuthPolicy,
  PreviewAuthResolverDeps,
  PreviewAuthToken,
  PreviewIntegrationRow,
} from "./types"

const log = new Log("modules.urlPreview.auth")

export const defaultPreviewAuthPolicy: PreviewAuthPolicy = {
  allowUserTokenFallbackInSpaceChats: false,
}

export async function resolvePreviewAuth(
  input: PreviewAuthInput,
  policy: PreviewAuthPolicy = defaultPreviewAuthPolicy,
): Promise<PreviewAuthToken | null> {
  return resolvePreviewAuthWithDeps(input, defaultDeps, policy)
}

export async function resolvePreviewAuthWithDeps(
  input: PreviewAuthInput,
  deps: PreviewAuthResolverDeps,
  policy: PreviewAuthPolicy = defaultPreviewAuthPolicy,
): Promise<PreviewAuthToken | null> {
  const spaceId = await deps.getChatSpaceId(input.chatId)

  if (spaceId != null) {
    const spaceIntegration = await deps.findSpaceIntegration(input.provider, spaceId)
    const token = readAuthToken(spaceIntegration, deps, { type: "space", spaceId })
    if (token) {
      return token
    }

    if (!policy.allowUserTokenFallbackInSpaceChats) {
      return null
    }
  }

  const userIntegration = await deps.findUserIntegration(input.provider, input.currentUserId)
  return readAuthToken(userIntegration, deps, { type: "user", userId: input.currentUserId })
}

function readAuthToken(
  row: PreviewIntegrationRow | null,
  deps: PreviewAuthResolverDeps,
  owner: PreviewAuthToken["owner"],
): PreviewAuthToken | null {
  if (!row) {
    return null
  }

  if (!row.accessTokenEncrypted || !row.accessTokenIv || !row.accessTokenTag) {
    log.warn("Preview integration is missing encrypted token data", {
      provider: row.provider,
      integrationId: row.id,
      ownerType: owner.type,
    })
    return null
  }

  const payload = decryptTokenPayload(row, deps, owner)
  if (!payload) {
    return null
  }

  const accessToken = accessTokenFromPayload(payload)
  if (!accessToken) {
    log.warn("Preview integration token payload is missing access token", {
      provider: row.provider,
      integrationId: row.id,
      ownerType: owner.type,
    })
    return null
  }

  return {
    provider: row.provider,
    accessToken,
    integrationId: row.id,
    owner,
  }
}

function decryptTokenPayload(
  row: PreviewIntegrationRow,
  deps: PreviewAuthResolverDeps,
  owner: PreviewAuthToken["owner"],
): unknown | null {
  try {
    return deps.decryptToken(row)
  } catch (error) {
    log.warn("Failed to read preview integration token payload", {
      error,
      provider: row.provider,
      integrationId: row.id,
      ownerType: owner.type,
    })
    return null
  }
}

export function accessTokenFromPayload(payload: unknown): string | null {
  const direct = stringField(payload, "access_token")
  if (direct) {
    return direct
  }

  const data = recordField(payload, "data")
  return stringField(data, "access_token")
}

function defaultDecryptToken(row: PreviewIntegrationRow): unknown {
  if (!row.accessTokenEncrypted || !row.accessTokenIv || !row.accessTokenTag) {
    return null
  }

  const text = decrypt({
    encrypted: row.accessTokenEncrypted,
    iv: row.accessTokenIv,
    authTag: row.accessTokenTag,
  })

  return JSON.parse(text) as unknown
}

const defaultDeps: PreviewAuthResolverDeps = {
  async getChatSpaceId(chatId) {
    const [chat] = await db.select({ spaceId: chats.spaceId }).from(chats).where(eq(chats.id, chatId)).limit(1)
    return chat?.spaceId ?? null
  },

  async findSpaceIntegration(provider, spaceId) {
    const [row] = await db
      .select()
      .from(integrations)
      .where(and(eq(integrations.provider, provider), eq(integrations.spaceId, spaceId)))
      .limit(1)
    return row ?? null
  },

  async findUserIntegration(provider, userId) {
    const [row] = await db
      .select()
      .from(integrations)
      .where(and(eq(integrations.provider, provider), eq(integrations.userId, userId), isNull(integrations.spaceId)))
      .limit(1)
    return row ?? null
  },

  decryptToken: defaultDecryptToken,
}

function recordField(value: unknown, key: string): Record<string, unknown> | null {
  const record = asRecord(value)
  return asRecord(record?.[key])
}

function stringField(value: unknown, key: string): string | null {
  const record = asRecord(value)
  const field = record?.[key]
  return typeof field === "string" && field.length > 0 ? field : null
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null
}
