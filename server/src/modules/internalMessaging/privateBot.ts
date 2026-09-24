import { ServerMessage } from "@inline-chat/protocol/core"
import { connectionManager } from "@in/server/ws/connections"
import { connectionDirectory } from "./directory"
import { internalMessaging } from "./service"
import { SessionId, UserId } from "@in/server/core/schema/identifiers"
import { sendMessageToRealtimeBotConnection } from "@in/server/realtime/message"
import { db } from "@in/server/db"
import { sessions, users, userNotDeleted } from "@in/server/db/schema"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { and, eq, isNull } from "drizzle-orm"
import { BotCapabilitiesModel } from "@in/server/db/models/botCapabilities"
import { hasChatSettingsCapability } from "@in/server/functions/bot.capabilitiesShared"

type PrivateKind = "botSettings" | "botFilesystem"

export async function requestRemoteBot(input: {
  botUserId: number
  actorUserId: number
  actorSessionId: number
  actorConnectionId?: string
  requestId: bigint
  kind: PrivateKind
  payload: ServerMessage["payload"]
}): Promise<{ status: "replied"; response: string } | { status: "unavailable" }> {
  if (!input.actorConnectionId) return { status: "unavailable" }
  const actor = connectionManager.getConnection(input.actorConnectionId)
  if (actor?.userId !== input.actorUserId || actor.sessionId !== input.actorSessionId) return { status: "unavailable" }
  const view = await connectionDirectory.list(input.botUserId)
  if (view.status === "unavailable") return { status: "unavailable" }
  const remote = view.connections.find((record) => record.isBot && record.bootId !== internalMessaging.bootId)
  if (!remote) return { status: "unavailable" }
  const result = await internalMessaging.requestPrivate({
    target: { kind: "connection", bootId: remote.bootId, connectionId: remote.connectionId, userId: UserId.make(input.botUserId), sessionId: SessionId.make(remote.sessionId) },
    origin: { kind: "connection", bootId: internalMessaging.bootId, connectionId: input.actorConnectionId, userId: UserId.make(input.actorUserId), sessionId: SessionId.make(input.actorSessionId) },
    requestId: input.requestId,
    payload: { kind: input.kind, request: Buffer.from(ServerMessage.toBinary({ payload: input.payload })).toString("base64") },
  })
  if (result.status !== "replied" || result.payload.kind !== input.kind) return { status: "unavailable" }
  // The request may outlive the caller's socket. Do not hand private bot
  // material back into a replacement connection that reused the same ID.
  if (connectionManager.getConnection(input.actorConnectionId) !== actor) {
    return { status: "unavailable" }
  }
  return { status: "replied", response: result.payload.response }
}

export function subscribePrivateBotRequests(): () => void {
  return internalMessaging.on("PrivateRequest", async (envelope) => {
    const { target, event } = envelope
    const actual = connectionManager.getConnection(target.connectionId)
    if (actual?.userId !== target.userId || actual.sessionId !== target.sessionId || actual.isBot !== true) return
    let payload: ServerMessage["payload"]
    try {
      payload = ServerMessage.fromBinary(Buffer.from(event.payload.request, "base64")).payload
    } catch { return }
    if (payload.oneofKind !== "bot") return
    const botEvent = payload.bot.event
    const matchingRequest = event.payload.kind === "botFilesystem"
      ? botEvent.oneofKind === "filesystemRequested" && botEvent.filesystemRequested.requestId === event.requestId
      : (botEvent.oneofKind === "chatSettingsRequested" && botEvent.chatSettingsRequested.requestId === event.requestId)
        || (botEvent.oneofKind === "chatSettingsItemInvoked" && botEvent.chatSettingsItemInvoked.requestId === event.requestId)
    if (!matchingRequest) return
    const request = botEvent.oneofKind === "filesystemRequested" ? botEvent.filesystemRequested
      : botEvent.oneofKind === "chatSettingsRequested" ? botEvent.chatSettingsRequested
      : botEvent.oneofKind === "chatSettingsItemInvoked" ? botEvent.chatSettingsItemInvoked
      : undefined
    if (!request || Number(request.actorUserId) !== event.originConnection.userId) return
    const chatId = Number(request.chatId)
    if (!Number.isSafeInteger(chatId) || chatId <= 0) return
    const [actorSession, chat] = await Promise.all([
      db.select({ id: sessions.id }).from(sessions).where(and(
        eq(sessions.id, event.originConnection.sessionId),
        eq(sessions.userId, event.originConnection.userId),
        isNull(sessions.revoked),
      )).limit(1).then(([row]) => row),
      db.query.chats.findFirst({ where: { id: chatId } }),
    ])
    if (!actorSession || !chat) return
    try {
      await AccessGuards.ensureChatAccess(chat, event.originConnection.userId)
      await AccessGuards.ensureChatAccess(chat, target.userId)
    } catch { return }
    if (!hasChatSettingsCapability(await BotCapabilitiesModel.getForBotUserId(target.userId))) return
    if (event.payload.kind === "botFilesystem") {
      const [owner] = await db.select({ id: users.id }).from(users).where(and(
        eq(users.id, target.userId), eq(users.bot, true),
        eq(users.botCreatorId, event.originConnection.userId), userNotDeleted(),
      )).limit(1)
      if (!owner) return
    }
    if (!internalMessaging.registerInboundPrivate(envelope)) return
    const sent = await sendMessageToRealtimeBotConnection(
      target.userId,
      target.connectionId,
      payload,
    )
    if (!sent) {
      internalMessaging.forgetInboundPrivate(envelope)
    }
  })
}
