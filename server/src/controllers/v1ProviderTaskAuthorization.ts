import type { DbChat } from "@in/server/db/schema"
import { InlineError } from "@in/server/types/errors"
import type { V1InputPeerInfo } from "./v1MessagingSchemas.effect"

export interface ProviderTaskTarget {
  readonly chatId: number
  readonly messageId: number
  readonly peerId: V1InputPeerInfo
  readonly spaceId?: number | undefined
}

export interface ProviderTaskAuthorizationContext {
  readonly currentUserId: number
}

interface ProviderTaskAuthorizationDependencies {
  readonly getAuthorizedChat: (chatId: number, userId: number) => Promise<Pick<
    DbChat,
    "id" | "maxUserId" | "minUserId" | "spaceId" | "type"
  >>
  readonly hasMessage: (chatId: number, messageId: number) => Promise<boolean>
  readonly requireSpaceMember: (spaceId: number, userId: number) => Promise<void>
}

const invalidTarget = () => new InlineError(InlineError.ApiError.PEER_INVALID)

const peerMatchesChat = (
  peerId: V1InputPeerInfo,
  chat: Pick<DbChat, "id" | "maxUserId" | "minUserId" | "type">,
  currentUserId: number,
): boolean => {
  if ("threadId" in peerId) {
    return chat.type === "thread" && chat.id === peerId.threadId
  }

  return chat.type === "private" &&
    Math.min(currentUserId, peerId.userId) === chat.minUserId &&
    Math.max(currentUserId, peerId.userId) === chat.maxUserId
}

/**
 * Security correction for the replacement provider path.
 *
 * The retained handlers historically trusted independently supplied space,
 * chat, message, and peer identifiers. Valid clients are unchanged, while a
 * mismatched or inaccessible target is rejected before provider calls or
 * message/task writes begin.
 */
export const makeProviderTaskAuthorizer = (
  dependencies: ProviderTaskAuthorizationDependencies,
) =>
  async (
    input: ProviderTaskTarget,
    context: ProviderTaskAuthorizationContext,
  ): Promise<void> => {
    const chat = await dependencies.getAuthorizedChat(
      input.chatId,
      context.currentUserId,
    )

    if (!peerMatchesChat(input.peerId, chat, context.currentUserId)) {
      throw invalidTarget()
    }

    const spaceId = chat.spaceId ?? input.spaceId
    if (
      spaceId === null ||
      spaceId === undefined ||
      (chat.spaceId !== null &&
        input.spaceId !== undefined &&
        chat.spaceId !== input.spaceId)
    ) {
      throw invalidTarget()
    }

    await dependencies.requireSpaceMember(spaceId, context.currentUserId)

    if (!(await dependencies.hasMessage(input.chatId, input.messageId))) {
      throw invalidTarget()
    }
  }
