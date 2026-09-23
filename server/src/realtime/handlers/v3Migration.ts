import {
  ConnectorProvider,
  type CreateExternalTaskInput,
  type CreateExternalTaskResult,
  type CreateSpaceInput,
  type CreateSpaceResult,
  type DeleteSpaceInput,
  type DeleteSpaceResult,
  type GetConnectorConfigInput,
  type GetConnectorConfigResult,
  type LeaveSpaceInput,
  type LeaveSpaceResult,
  type LogOutResult,
  type SetConnectorConfigInput,
  type SetConnectorConfigResult,
  type UnregisterDeviceResult,
  type UpdateDialogArchivedInput,
  type UpdateDialogArchivedResult,
  type UpdateSessionInput,
  type UpdateSessionResult,
} from "@inline-chat/protocol/core"
import { and, eq } from "drizzle-orm"
import { db } from "@in/server/db"
import { chats, dialogs, members, spaces } from "@in/server/db/schema"
import { SessionsModel } from "@in/server/db/models/sessions"
import { handler as createSpace } from "@in/server/methods/createSpace"
import { handler as deleteSpace } from "@in/server/methods/deleteSpace"
import { handler as leaveSpace } from "@in/server/methods/leaveSpace"
import { handler as getIntegrations } from "@in/server/methods/getIntegrations"
import { handler as getNotionDatabases } from "@in/server/methods/notion/getNotionDatabases"
import { handler as getLinearTeams } from "@in/server/methods/linear/getLinearTeams"
import { handler as saveNotionDatabaseId } from "@in/server/methods/notion/saveNotionDatabaseId"
import { handler as saveLinearTeamId } from "@in/server/methods/linear/saveLinearTeamId"
import { handler as createNotionTask } from "@in/server/methods/notion/createNotionTask"
import { handler as createLinearIssue } from "@in/server/methods/createLinearIssue"
import { handler as logOut } from "@in/server/methods/logout"
import { handler as updateDialog } from "@in/server/methods/updateDialog"
import { syncTimeZoneForElectedAppleSession } from "@in/server/modules/users/timeZoneSync"
import { encodeChatForUser } from "@in/server/realtime/encoders/encodeChat"
import { encodeDialog } from "@in/server/realtime/encoders/encodeDialog"
import { encodeMember } from "@in/server/realtime/encoders/encodeMember"
import { encodeSpace } from "@in/server/realtime/encoders/encodeSpace"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"
import { validateIanaTimezone, validateUpToFourSegementSemver } from "@in/server/utils/validate"
import { encodeSession } from "./user.getSessions"

const legacyContext = (context: HandlerContext) => ({
  currentUserId: context.userId,
  currentSessionId: context.sessionId,
  ip: undefined,
  // Keep the V3 deadline attached when a retained handler is the owner of the
  // operation. Legacy handlers that do not consume it remain unchanged.
  signal: context.signal,
})

const safeId = (value: bigint): number => {
  const id = Number(value)
  if (!Number.isSafeInteger(id) || id <= 0) throw RealtimeRpcError.BadRequest()
  return id
}

const spaceScope = (scope: GetConnectorConfigInput["scope"]): number => {
  if (scope?.type.oneofKind !== "space") throw RealtimeRpcError.BadRequest()
  return safeId(scope.type.space.spaceId)
}

export async function createSpaceV3(
  input: CreateSpaceInput,
  context: HandlerContext,
): Promise<CreateSpaceResult> {
  const created = await createSpace({ name: input.name, photoFileUniqueId: input.photoFileUniqueId }, legacyContext(context))
  const spaceId = created.space.id
  const chatId = created.chats[0]?.id
  if (!chatId) throw RealtimeRpcError.InternalError()
  const [space, member, chat, dialog] = await Promise.all([
    db._query.spaces.findFirst({ where: eq(spaces.id, spaceId) }),
    db._query.members.findFirst({ where: and(eq(members.spaceId, spaceId), eq(members.userId, context.userId)) }),
    db._query.chats.findFirst({ where: eq(chats.id, chatId) }),
    db._query.dialogs.findFirst({ where: and(eq(dialogs.chatId, chatId), eq(dialogs.userId, context.userId)) }),
  ])
  if (!space || !member || !chat || !dialog) throw RealtimeRpcError.InternalError()
  return {
    space: encodeSpace(space, { encodingForUserId: context.userId }),
    member: encodeMember(member),
    chat: await encodeChatForUser(chat, { encodingForUserId: context.userId }),
    dialog: encodeDialog(dialog, { unreadCount: 0 }),
  }
}

export async function deleteSpaceV3(
  input: DeleteSpaceInput,
  context: HandlerContext,
): Promise<DeleteSpaceResult> {
  await deleteSpace({ spaceId: safeId(input.spaceId) }, legacyContext(context))
  return {}
}

export async function leaveSpaceV3(
  input: LeaveSpaceInput,
  context: HandlerContext,
): Promise<LeaveSpaceResult> {
  await leaveSpace({ spaceId: safeId(input.spaceId) }, legacyContext(context))
  return {}
}

export async function getConnectorConfigV3(
  input: GetConnectorConfigInput,
  context: HandlerContext,
): Promise<GetConnectorConfigResult> {
  const spaceId = spaceScope(input.scope)
  const integrations = await getIntegrations({ userId: context.userId, spaceId }, legacyContext(context))
  if (input.provider === ConnectorProvider.NOTION) {
    const options = await getNotionDatabases({ spaceId }, legacyContext(context))
    return {
      options: options.map((option) => ({ id: option.id, title: option.title, subtitle: option.icon })),
      selectedId: integrations.notionDatabaseId,
    }
  }
  if (input.provider === ConnectorProvider.LINEAR) {
    const options = await getLinearTeams({ spaceId }, legacyContext(context))
    return {
      options: options.map((option) => ({ id: option.id, title: option.name, subtitle: option.key })),
      selectedId: integrations.linearTeamId,
    }
  }
  throw RealtimeRpcError.BadRequest()
}

export async function setConnectorConfigV3(
  input: SetConnectorConfigInput,
  context: HandlerContext,
): Promise<SetConnectorConfigResult> {
  const spaceId = spaceScope(input.scope)
  if (!input.selectedId) throw RealtimeRpcError.BadRequest()
  if (input.provider === ConnectorProvider.NOTION) {
    await saveNotionDatabaseId({ spaceId: String(spaceId), databaseId: input.selectedId }, legacyContext(context))
    return {}
  }
  if (input.provider === ConnectorProvider.LINEAR) {
    await saveLinearTeamId({ spaceId: String(spaceId), teamId: input.selectedId }, legacyContext(context))
    return {}
  }
  throw RealtimeRpcError.BadRequest()
}

type LegacyPeer = { threadId: number } | { userId: number }

const peerForLegacy = (peerId: CreateExternalTaskInput["peerId"], currentUserId: number): LegacyPeer => {
  const type = peerId?.type
  if (type?.oneofKind === "chat") return { threadId: safeId(type.chat.chatId) }
  if (type?.oneofKind === "user") return { userId: safeId(type.user.userId) }
  if (type?.oneofKind === "self") return { userId: currentUserId }
  throw RealtimeRpcError.BadRequest()
}

const chatIdForPeer = async (peer: ReturnType<typeof peerForLegacy>, currentUserId: number): Promise<number> => {
  if ("threadId" in peer) return peer.threadId
  const low = Math.min(peer.userId, currentUserId)
  const high = Math.max(peer.userId, currentUserId)
  const chat = await db._query.chats.findFirst({
    where: and(eq(chats.type, "private"), eq(chats.minUserId, low), eq(chats.maxUserId, high)),
  })
  if (!chat) throw RealtimeRpcError.ChatIdInvalid()
  return chat.id
}

export async function createExternalTaskV3(
  input: CreateExternalTaskInput,
  context: HandlerContext,
): Promise<CreateExternalTaskResult> {
  const spaceId = spaceScope(input.scope)
  const messageId = safeId(input.messageId)
  const peerId = peerForLegacy(input.peerId, context.userId)
  const chatId = await chatIdForPeer(peerId, context.userId)
  if (input.provider === ConnectorProvider.NOTION) {
    const result = await createNotionTask({ spaceId, messageId, chatId, peerId }, legacyContext(context))
    return { url: result.url }
  }
  if (input.provider === ConnectorProvider.LINEAR) {
    const result = await createLinearIssue({
      text: "",
      messageId,
      chatId,
      peerId,
      fromId: context.userId,
      spaceId,
    }, legacyContext(context))
    if (!result.link) throw RealtimeRpcError.InternalError()
    return { url: result.link }
  }
  throw RealtimeRpcError.BadRequest()
}

export async function unregisterDeviceV3(context: HandlerContext): Promise<UnregisterDeviceResult> {
  await SessionsModel.clearApplePushToken(context.sessionId)
  return {}
}

export async function logOutV3(context: HandlerContext): Promise<LogOutResult> {
  await logOut({}, legacyContext(context), { preserveConnectionId: context.connectionId })
  return { loggedOut: true }
}

const boundedOptional = (value: string | undefined, maxLength: number): string | undefined => {
  if (value === undefined) return undefined
  const trimmed = value.trim()
  if (!trimmed || trimmed.length > maxLength) throw RealtimeRpcError.BadRequest()
  return trimmed
}

export async function updateSessionV3(
  input: UpdateSessionInput,
  context: HandlerContext,
): Promise<UpdateSessionResult> {
  const timezone = boundedOptional(input.timeZone, 256)
  if (timezone && !validateIanaTimezone(timezone)) throw RealtimeRpcError.BadRequest()
  const deviceName = boundedOptional(input.deviceName, 256)
  const clientVersion = boundedOptional(input.clientVersion, 64)
  const osVersion = boundedOptional(input.osVersion, 64)
  if (clientVersion && !validateUpToFourSegementSemver(clientVersion)) throw RealtimeRpcError.BadRequest()
  if (osVersion && !validateUpToFourSegementSemver(osVersion)) throw RealtimeRpcError.BadRequest()
  if (!timezone && !deviceName && !clientVersion && !osVersion) throw RealtimeRpcError.BadRequest()

  const session = await SessionsModel.updateMetadata(context.sessionId, context.userId, {
    timezone,
    deviceName,
    clientVersion,
    osVersion,
  })
  if (timezone) {
    await syncTimeZoneForElectedAppleSession({
      userId: context.userId,
      sessionId: context.sessionId,
      timeZone: timezone,
    })
  }
  return { session: encodeSession(session, context.sessionId) }
}

export async function updateDialogArchivedV3(
  input: UpdateDialogArchivedInput,
  context: HandlerContext,
): Promise<UpdateDialogArchivedResult> {
  const peerId = peerForLegacy(input.peerId, context.userId)
  await updateDialog({
    ...("userId" in peerId ? { peerUserId: peerId.userId } : { peerThreadId: peerId.threadId }),
    archived: input.archived,
  }, legacyContext(context))
  const outputPeer = "userId" in peerId
    ? { type: { oneofKind: "user" as const, user: { userId: BigInt(peerId.userId) } } }
    : { type: { oneofKind: "chat" as const, chat: { chatId: BigInt(peerId.threadId) } } }
  return {
    updates: [{
      update: {
        oneofKind: "dialogArchived",
        dialogArchived: { peerId: outputPeer, archived: input.archived },
      },
    }],
  }
}
