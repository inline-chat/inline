import { db } from "@in/server/db"
import { chats } from "@in/server/db/schema"
import {
  accessTokenFromPayload,
  resolveIntegrationAuth,
  resolveIntegrationAuthCandidates,
  resolveIntegrationAuthCandidatesWithDeps,
  resolveIntegrationAuthWithDeps,
  type IntegrationAuthPolicy,
} from "@in/server/modules/integrations/authResolver"
import { eq } from "drizzle-orm"
import type {
  PreviewAuthInput,
  PreviewAuthPolicy,
  PreviewAuthResolverDeps,
  PreviewAuthToken,
} from "./types"

export const defaultPreviewAuthPolicy: PreviewAuthPolicy = {
  scopeOrderInSpace: ["user", "space"],
}

export async function resolvePreviewAuth(
  input: PreviewAuthInput,
  policy: PreviewAuthPolicy = defaultPreviewAuthPolicy,
): Promise<PreviewAuthToken | null> {
  const [chat] = await db
    .select({ spaceId: chats.spaceId })
    .from(chats)
    .where(eq(chats.id, input.chatId))
    .limit(1)
  return resolveIntegrationAuth(
    {
      provider: input.provider,
      currentUserId: input.currentUserId,
      spaceId: chat?.spaceId ?? null,
    },
    integrationPolicy(policy),
  )
}

export async function resolvePreviewAuthCandidates(
  input: PreviewAuthInput,
  policy: PreviewAuthPolicy = defaultPreviewAuthPolicy,
): Promise<PreviewAuthToken[]> {
  const [chat] = await db
    .select({ spaceId: chats.spaceId })
    .from(chats)
    .where(eq(chats.id, input.chatId))
    .limit(1)
  return resolveIntegrationAuthCandidates(
    {
      provider: input.provider,
      currentUserId: input.currentUserId,
      spaceId: chat?.spaceId ?? null,
    },
    integrationPolicy(policy),
  )
}

export async function resolvePreviewAuthWithDeps(
  input: PreviewAuthInput,
  deps: PreviewAuthResolverDeps,
  policy: PreviewAuthPolicy = defaultPreviewAuthPolicy,
): Promise<PreviewAuthToken | null> {
  const spaceId = await deps.getChatSpaceId(input.chatId)
  return resolveIntegrationAuthWithDeps(
    {
      provider: input.provider,
      currentUserId: input.currentUserId,
      spaceId,
    },
    deps,
    integrationPolicy(policy),
  )
}

export async function resolvePreviewAuthCandidatesWithDeps(
  input: PreviewAuthInput,
  deps: PreviewAuthResolverDeps,
  policy: PreviewAuthPolicy = defaultPreviewAuthPolicy,
): Promise<PreviewAuthToken[]> {
  const spaceId = await deps.getChatSpaceId(input.chatId)
  return resolveIntegrationAuthCandidatesWithDeps(
    {
      provider: input.provider,
      currentUserId: input.currentUserId,
      spaceId,
    },
    deps,
    integrationPolicy(policy),
  )
}

function integrationPolicy(policy: PreviewAuthPolicy): IntegrationAuthPolicy {
  return {
    scopeOrderInSpace: policy.scopeOrderInSpace,
  }
}

export { accessTokenFromPayload }
