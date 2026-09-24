import { ChatId, UserId } from "@in/server/core/schema/identifiers"
import { db } from "@in/server/db"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { connectionManager } from "@in/server/ws/connections"
import { UpdateComposeAction_ComposeAction, UserStatus_Status, type Update } from "@inline-chat/protocol/core"
import { encodeDate } from "@in/server/realtime/encoders/helpers"
import { outboundPublications, type OutboundPublication } from "./outbound"
import { internalMessaging } from "./service"

type ComposeAction = "none" | "typing" | "uploadingDocument" | "uploadingPhoto" | "uploadingVideo" | "recordingVoice"

class ComposePublication implements OutboundPublication {
  readonly key: string

  constructor(
    private readonly targetUserId: number,
    private readonly actorUserId: number,
    private readonly chatId: number,
    private action: ComposeAction,
  ) {
    this.key = `transient:compose:${targetUserId}:${actorUserId}:${chatId}`
  }

  async run(): Promise<void> {
    await internalMessaging.publish({ target: { kind: "user", userId: UserId.make(this.targetUserId) },
      event: { kind: "TransientRealtime", payload: {
        kind: "composeChanged", userId: UserId.make(this.actorUserId), chatId: ChatId.make(this.chatId), action: this.action,
      } } })
  }

  merge(next: OutboundPublication): void {
    if (!(next instanceof ComposePublication) || next.key !== this.key) {
      throw new Error("Compose publication merged with an incompatible outbound hint")
    }
    this.action = next.action
  }
}

class PresencePublication implements OutboundPublication {
  readonly key: string

  constructor(
    private readonly targetUserId: number,
    private readonly actorUserId: number,
    private online: boolean,
    private lastOnlineMs: number | null,
  ) {
    this.key = `transient:presence:${targetUserId}:${actorUserId}`
  }

  async run(): Promise<void> {
    await internalMessaging.publish({ target: { kind: "user", userId: UserId.make(this.targetUserId) },
      event: { kind: "TransientRealtime", payload: {
        kind: "userPresenceChanged", userId: UserId.make(this.actorUserId), online: this.online, lastOnlineMs: this.lastOnlineMs,
      } } })
  }

  merge(next: OutboundPublication): void {
    if (!(next instanceof PresencePublication) || next.key !== this.key) {
      throw new Error("Presence publication merged with an incompatible outbound hint")
    }
    this.online = next.online
    this.lastOnlineMs = next.lastOnlineMs
  }
}

class BotPresencePublication implements OutboundPublication {
  readonly key: string

  constructor(
    private readonly targetUserId: number,
    private readonly botUserId: number,
    private readonly chatId: number,
    private activityId: string,
  ) {
    this.key = `transient:bot-presence:${targetUserId}:${botUserId}:${chatId}`
  }

  async run(): Promise<void> {
    await internalMessaging.publish({ target: { kind: "user", userId: UserId.make(this.targetUserId) },
      event: { kind: "TransientRealtime", payload: {
        kind: "botPresenceChanged", botUserId: UserId.make(this.botUserId), chatId: ChatId.make(this.chatId), activityId: this.activityId,
      } } })
  }

  merge(next: OutboundPublication): void {
    if (!(next instanceof BotPresencePublication) || next.key !== this.key) {
      throw new Error("Bot-presence publication merged with an incompatible outbound hint")
    }
    this.activityId = next.activityId
  }
}

/** Transient hints are coalesced and never add broker latency to local delivery. */
export function publishComposeAction(targetUserId: number, actorUserId: number, chatId: number, action: ComposeAction): void {
  outboundPublications.enqueue(new ComposePublication(targetUserId, actorUserId, chatId, action))
}

export function publishUserPresence(targetUserId: number, actorUserId: number, online: boolean, lastOnline: Date | null): void {
  outboundPublications.enqueue(new PresencePublication(targetUserId, actorUserId, online, lastOnline?.getTime() ?? null))
}

export function publishBotPresence(targetUserId: number, botUserId: number, chatId: number, activityId: string): void {
  outboundPublications.enqueue(new BotPresencePublication(targetUserId, botUserId, chatId, activityId))
}

const composeValue: Record<ComposeAction, UpdateComposeAction_ComposeAction> = {
  none: UpdateComposeAction_ComposeAction.NONE,
  typing: UpdateComposeAction_ComposeAction.TYPING,
  uploadingDocument: UpdateComposeAction_ComposeAction.UPLOADING_DOCUMENT,
  uploadingPhoto: UpdateComposeAction_ComposeAction.UPLOADING_PHOTO,
  uploadingVideo: UpdateComposeAction_ComposeAction.UPLOADING_VIDEO,
  recordingVoice: UpdateComposeAction_ComposeAction.RECORDING_VOICE,
}

export function subscribeTransientRealtime(): () => void {
  return internalMessaging.on("TransientRealtime", async ({ target, event }) => {
    const recipient = target.userId
    if (connectionManager.getUserConnections(recipient).length === 0) return
    const payload = event.payload
    if (payload.kind === "botPresenceChanged") return // dedicated current-value handler
    if (payload.kind === "userPresenceChanged") {
      const update: Update = { update: { oneofKind: "updateUserStatus", updateUserStatus: {
        userId: BigInt(payload.userId), status: {
          online: payload.online ? UserStatus_Status.ONLINE : UserStatus_Status.OFFLINE,
          lastOnline: { date: payload.lastOnlineMs === null ? undefined : encodeDate(new Date(payload.lastOnlineMs)) },
        },
      } } }
      await RealtimeUpdates.pushToUser(recipient, [update])
      return
    }
    const chat = await db.query.chats.findFirst({ where: { id: payload.chatId } })
    if (!chat) return
    try { await AccessGuards.ensureChatAccess(chat, recipient) } catch { return }
    const update: Update = { update: { oneofKind: "updateComposeAction", updateComposeAction: {
      userId: BigInt(payload.userId),
      peerId: Encoders.peerFromChat(chat, { currentUserId: recipient }),
      action: composeValue[payload.action],
    } } }
    await RealtimeUpdates.pushToUser(recipient, [update])
  })
}
