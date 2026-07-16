import type { DbChat } from "@in/server/db/schema"
import { MembersModel } from "@in/server/db/models/members"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { getChatById } from "@in/server/modules/subthreads"
import { hasThreadAccessGrant } from "@in/server/modules/authorization/threadAccess"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { resolveChatPermissions } from "@in/server/modules/authorization/chatPermissions"
import type { Transaction } from "@in/server/db/types"

export const AccessGuards = {
  ensureChatAccess,
  ensureChatInfoEditAccess,
  ensureSpaceMember,
}

// TODO: this can all be optimized to use less queries and be smarter about caching with a simpler API.

async function ensureChatAccess(chat: DbChat, userId: number) {
  if (chat.type === "private") {
    if (chat.minUserId !== userId && chat.maxUserId !== userId) {
      throw RealtimeRpcError.PeerIdInvalid()
    }
    return
  }

  if (await hasThreadAccessGrant(chat.id, userId)) {
    return
  }

  if (chat.parentChatId != null) {
    const parentChat = await getChatById(chat.parentChatId)
    if (!parentChat) {
      throw RealtimeRpcError.PeerIdInvalid()
    }

    await ensureInheritedChatAccess(parentChat, userId)
    return
  }

  await ensureTopLevelChatAccess(chat, userId)
}

async function ensureChatInfoEditAccess(chat: DbChat, userId: number, query?: Pick<Transaction, "select">) {
  const permissions = await resolveChatPermissions(chat, userId, query)
  if (!permissions.canUpdateInfo) {
    throw RealtimeRpcError.PeerIdInvalid()
  }
}

async function ensureInheritedChatAccess(chat: DbChat, userId: number) {
  if (chat.parentChatId != null) {
    const parentChat = await getChatById(chat.parentChatId)
    if (!parentChat) {
      throw RealtimeRpcError.PeerIdInvalid()
    }

    await ensureInheritedChatAccess(parentChat, userId)
    return
  }

  await ensureTopLevelChatAccess(chat, userId)
}

async function ensureTopLevelChatAccess(chat: DbChat, userId: number) {
  if (chat.type === "private") {
    if (chat.minUserId !== userId && chat.maxUserId !== userId) {
      throw RealtimeRpcError.PeerIdInvalid()
    }
    return
  }

  if (!chat.spaceId) {
    await ensureThreadAccessGrant(chat.id, userId)
    return
  }

  await ensureSpaceMember(chat.spaceId, userId)

  if (chat.publicThread) {
    const member = await MembersModel.getMemberByUserId(chat.spaceId, userId)
    if (!member || member.canAccessPublicChats === false) {
      throw RealtimeRpcError.PeerIdInvalid()
    }
    return
  }

  await ensureThreadAccessGrant(chat.id, userId)
}

async function ensureSpaceMember(spaceId: number, userId: number) {
  const cachedMember = AccessGuardsCache.getSpaceMember(spaceId, userId)
  if (cachedMember !== undefined) {
    if (!cachedMember) {
      throw RealtimeRpcError.SpaceIdInvalid()
    }
    return
  }

  const isMember = await MembersModel.isUserMemberOfSpace(spaceId, userId)
  if (isMember) {
    AccessGuardsCache.setSpaceMember(spaceId, userId)
  }

  if (!isMember) {
    throw RealtimeRpcError.SpaceIdInvalid()
  }
}

async function ensureThreadAccessGrant(chatId: number, userId: number) {
  const exists = await hasThreadAccessGrant(chatId, userId)
  if (!exists) {
    throw RealtimeRpcError.PeerIdInvalid()
  }
}
