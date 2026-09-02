import type { DbSpace, DbUser } from "@in/server/db/schema"
import { UsersModel } from "@in/server/db/models/users"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { FunctionContext } from "@in/server/functions/_types"

import type { InviteToSpaceInput, InviteToSpaceResult } from "@inline-chat/protocol/core"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { isValidEmail, isValidSpaceId } from "@in/server/utils/validate"
import { sendEmail } from "@in/server/utils/email"
import { Notifications } from "@in/server/modules/notifications/notifications"
import { getCachedUserName } from "@in/server/modules/cache/userNames"
import { Log } from "@in/server/utils/log"
import { BotAlerts } from "@in/server/modules/bot-events/alerts"
import {
  addSpaceMember,
  SpaceMemberAdmissionError,
  type SpaceMemberTarget,
} from "@in/server/functions/space.addMember.shared"

const log = new Log("space.inviteToSpace")

export const inviteToSpace = async (
  input: InviteToSpaceInput,
  context: FunctionContext,
): Promise<InviteToSpaceResult> => {
  const spaceId = Number(input.spaceId)
  if (!isValidSpaceId(spaceId)) {
    throw RealtimeRpcError.BadRequest()
  }
  const requestedRole = getRequestedRole(input)
  const inviteTarget = getInviteTarget(input)

  const outcome = await addSpaceMember({
    spaceId,
    actorUserId: context.currentUserId,
    target: inviteTarget,
    admission: "invite",
    role: requestedRole,
    canAccessPublicChats:
      input.role?.role.oneofKind === "member" ? input.role.role.member.canAccessPublicChats : true,
  }).catch((error: unknown) => {
    if (error instanceof SpaceMemberAdmissionError) {
      throw RealtimeRpcError.SpaceAdminRequired()
    }
    throw error
  })

  // Best-effort internal alert (should never affect the user action).
  void BotAlerts.spaceInvite({
    inviterUserId: context.currentUserId,
    invitedUserId: outcome.user.id,
    spaceId: outcome.space.id,
    spaceName: outcome.space.name,
  }).catch((error: unknown) => {
    log.error(error, "Failed to send internal space-invite alert", { spaceId, userId: outcome.user.id })
  })

  // Send invite
  void sendInvite(outcome.user, outcome.space, context)
    .then(() => {
      log.info("Invite sent", { spaceId, userId: outcome.user.id })
    })
    .catch((error) => {
      log.error(error, "Failed to send invite", { spaceId, userId: outcome.user.id })
    })

  return {
    user: Encoders.user({ user: outcome.user, min: false }),
    member: Encoders.member(outcome.member),
  }
}

// ------------------------------------------------------------

type RequestedInviteRole = "member" | "admin" | undefined

function getRequestedRole(input: InviteToSpaceInput): RequestedInviteRole {
  const roleKind = input.role?.role.oneofKind
  if (roleKind && roleKind !== "member" && roleKind !== "admin") {
    throw RealtimeRpcError.BadRequest()
  }
  return roleKind
}

function getInviteTarget(input: InviteToSpaceInput): SpaceMemberTarget {
  switch (input.via.oneofKind) {
    case "userId": {
      const userId = Number(input.via.userId)
      if (!Number.isSafeInteger(userId) || userId <= 0) {
        throw RealtimeRpcError.UserIdInvalid()
      }
      return { kind: "userId", userId }
    }
    case "email": {
      const email = input.via.email.toLowerCase().trim()
      if (!isValidEmail(email)) {
        throw RealtimeRpcError.EmailInvalid()
      }
      return { kind: "email", email }
    }
    case "phoneNumber":
      return { kind: "phoneNumber", phoneNumber: UsersModel.normalizePhoneNumber(input.via.phoneNumber) }
    default:
      throw RealtimeRpcError.BadRequest()
  }
}

async function sendInvite(user: DbUser, space: DbSpace, context: FunctionContext) {
  const invitedByUserName = await getCachedUserName(context.currentUserId)

  // Send invite to email or via push notification
  if (user.email) {
    await sendEmail({
      to: user.email,
      content: {
        template: "invitedToSpace",
        variables: {
          email: user.email,
          spaceName: space?.name ?? "Unnamed Space",
          isExistingUser: user.pendingSetup === false || user.emailVerified == true || user.phoneVerified == true,
          firstName: user.firstName ?? undefined,
          invitedByUserName: invitedByUserName,
        },
      },
    })
  }

  if (!user.pendingSetup) {
    let inviterName =
      invitedByUserName?.firstName ??
      (invitedByUserName?.username ? `@${invitedByUserName.username}` : invitedByUserName?.email)

    // Now send push notification
    await Notifications.sendToUser({
      userId: user.id,
      payload: {
        kind: "alert",
        senderUserId: context.currentUserId,
        threadId: `invite_${space.id}`,
        title: `${inviterName ?? "Someone"} added you to "${space?.name ?? "Unnamed"}" space`,
        body: `Open the app, tap on the space name to start chatting.`,
      },
    })
  }
}
