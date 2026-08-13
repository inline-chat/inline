import type { InviteToInlineInput, InviteToInlineResult, User } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { UsersModel } from "@in/server/db/models/users"
import { chats, dialogs, type DbUser } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { handler as createPrivateChat } from "@in/server/methods/createPrivateChat"
import { Notifications } from "@in/server/modules/notifications/notifications"
import { InMemoryRateLimiter } from "@in/server/modules/oauth/rateLimiter"
import { encodePublicUser } from "@in/server/modules/privacy/userPrivacy"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { getCachedUserName } from "@in/server/modules/cache/userNames"
import { sendEmail } from "@in/server/utils/email"
import { isValidEmail } from "@in/server/utils/validate"
import { Log } from "@in/server/utils/log"
import { and, eq } from "drizzle-orm"

const INVITES_PER_HOUR = 20
const INVITE_DELIVERY_COOLDOWN_MS = 10 * 60_000
const defaultRequestLimiter = new InMemoryRateLimiter({ capacity: 10_000 })

type NormalizedInviteTarget =
  | { kind: "userId"; userId: number }
  | { kind: "email"; email: string }
  | { kind: "phoneNumber"; phoneNumber: string }

type InviteDelivery = (
  user: DbUser,
  target: NormalizedInviteTarget,
  context: FunctionContext,
) => Promise<void>

export class InviteDeliveryGuard {
  private readonly limiter = new InMemoryRateLimiter({ capacity: 10_000 })
  private readonly inFlight = new Map<string, Promise<boolean>>()

  async run(input: { key: string; nowMs: number; deliver: () => Promise<void> }): Promise<boolean> {
    const inFlight = this.inFlight.get(input.key)
    if (inFlight) {
      return inFlight
    }

    const rate = this.limiter.consume({
      key: input.key,
      nowMs: input.nowMs,
      rule: { max: 1, windowMs: INVITE_DELIVERY_COOLDOWN_MS },
    })
    if (!rate.allowed) {
      return false
    }

    const delivery = Promise.resolve()
      .then(input.deliver)
      .then(() => true)
      .catch((error) => {
        this.limiter.reset(input.key)
        throw error
      })
    this.inFlight.set(input.key, delivery)

    try {
      return await delivery
    } finally {
      if (this.inFlight.get(input.key) === delivery) {
        this.inFlight.delete(input.key)
      }
    }
  }
}

const defaultDeliveryGuard = new InviteDeliveryGuard()

type InviteToInlineOptions = {
  requestLimiter?: InMemoryRateLimiter
  deliveryGuard?: InviteDeliveryGuard
  nowMs?: () => number
  deliver?: InviteDelivery
}

export async function inviteToInline(
  input: InviteToInlineInput,
  context: FunctionContext,
  options: InviteToInlineOptions = {},
): Promise<InviteToInlineResult> {
  const target = normalizeInviteTarget(input)
  const nowMs = options.nowMs ?? Date.now
  const requestRate = (options.requestLimiter ?? defaultRequestLimiter).consume({
    key: `invite-inline:${context.currentUserId}`,
    nowMs: nowMs(),
    rule: { max: INVITES_PER_HOUR, windowMs: 60 * 60_000 },
  })
  if (!requestRate.allowed) {
    throw RealtimeRpcError.RateLimit()
  }

  const invitedUser = await resolveInvitedUser(target)
  if (invitedUser.id === context.currentUserId) {
    throw RealtimeRpcError.UserIdInvalid()
  }

  const contactPeer = target.kind === "userId" ? undefined : idOnlyUser(invitedUser.id)

  await createPrivateChat(
    { userId: String(invitedUser.id) },
    {
      currentUserId: context.currentUserId,
      currentSessionId: context.currentSessionId,
      ip: undefined,
    },
    { peerForCurrentUser: contactPeer },
  )

  let encodedUser = contactPeer
  if (!encodedUser) {
    const peer = await UsersModel.getUserWithProfile(invitedUser.id)
    if (!peer) {
      throw RealtimeRpcError.UserIdInvalid()
    }
    encodedUser = encodePublicUser({ user: peer, photoFile: peer.photoFile ?? undefined })
  }

  const { chat, dialog } = await loadPrivateChatProjection(context.currentUserId, invitedUser.id)
  const unreadCount = await DialogsModel.getUnreadCount(chat.id, context.currentUserId)
  const delivery = () =>
    (options.deliveryGuard ?? defaultDeliveryGuard).run({
      key: `${context.currentUserId}:${invitedUser.id}`,
      nowMs: nowMs(),
      deliver: () => (options.deliver ?? deliverInvite)(invitedUser, target, context),
    })

  if (target.kind === "email") {
    await delivery()
  } else {
    void delivery().catch((error) => {
      Log.shared.error("Failed to deliver general Inline invitation", { error, invitedUserId: invitedUser.id })
    })
  }

  return {
    user: encodedUser,
    chat: await Encoders.chatForUser(chat, { encodingForUserId: context.currentUserId }),
    dialog: Encoders.dialog(dialog, { unreadCount }),
  }
}

function normalizeInviteTarget(input: InviteToInlineInput): NormalizedInviteTarget {
  switch (input.via.oneofKind) {
    case "userId": {
      const userId = Number(input.via.userId)
      if (!Number.isSafeInteger(userId) || userId <= 0) {
        throw RealtimeRpcError.UserIdInvalid()
      }
      return { kind: "userId", userId }
    }
    case "email": {
      const email = input.via.email.trim().toLowerCase()
      if (!isValidEmail(email)) throw RealtimeRpcError.EmailInvalid()
      return { kind: "email", email }
    }
    case "phoneNumber":
      return {
        kind: "phoneNumber",
        phoneNumber: UsersModel.normalizePhoneNumber(input.via.phoneNumber),
      }
    default:
      throw RealtimeRpcError.BadRequest()
  }
}

async function resolveInvitedUser(target: NormalizedInviteTarget): Promise<DbUser> {
  switch (target.kind) {
    case "userId": {
      const user = await UsersModel.getActiveUserById(target.userId)
      if (!user) throw RealtimeRpcError.UserIdInvalid()
      return user
    }
    case "email": {
      const existing = await UsersModel.getUserByEmail(target.email)
      if (UsersModel.isDeleted(existing)) throw RealtimeRpcError.UserIdInvalid()
      return existing ?? UsersModel.createUserWhenInvited({ email: target.email })
    }
    case "phoneNumber": {
      const existing = await UsersModel.getUserByPhoneNumber(target.phoneNumber)
      if (UsersModel.isDeleted(existing)) throw RealtimeRpcError.UserIdInvalid()
      return existing ?? UsersModel.createUserWhenInvited({ phoneNumber: target.phoneNumber })
    }
  }
}

function idOnlyUser(userId: number): User {
  return { id: BigInt(userId), min: true }
}

async function loadPrivateChatProjection(currentUserId: number, peerUserId: number) {
  const minUserId = Math.min(currentUserId, peerUserId)
  const maxUserId = Math.max(currentUserId, peerUserId)
  const chat = await db._query.chats.findFirst({
    where: and(eq(chats.type, "private"), eq(chats.minUserId, minUserId), eq(chats.maxUserId, maxUserId)),
  })
  if (!chat) throw RealtimeRpcError.InternalError()
  const dialog = await db._query.dialogs.findFirst({
    where: and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, currentUserId)),
  })
  if (!dialog) throw RealtimeRpcError.InternalError()
  return { chat, dialog }
}

async function deliverInvite(user: DbUser, target: NormalizedInviteTarget, context: FunctionContext) {
  const inviter = await getCachedUserName(context.currentUserId)
  const inviterName = inviter?.firstName ?? (inviter?.username ? `@${inviter.username}` : "Someone")

  if (target.kind === "email" && user.email) {
    await sendEmail({
      to: user.email,
      content: {
        template: "invitedToInline",
        variables: {
          firstName: user.firstName ?? undefined,
          invitedByName: inviterName,
        },
      },
    })
  }

  if (!user.pendingSetup) {
    void Notifications.sendToUser({
      userId: user.id,
      payload: {
        kind: "alert",
        senderUserId: context.currentUserId,
        threadId: `invite_inline_${context.currentUserId}`,
        title: `${inviterName} invited you to chat on Inline`,
        body: "Open Inline to start chatting.",
      },
    }).catch((error) => {
      Log.shared.error("Failed to notify existing user about general Inline invitation", {
        error,
        invitedUserId: user.id,
      })
    })
  }
}
