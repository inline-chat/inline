import { db } from "@in/server/db"
import { and, eq } from "drizzle-orm"
import { members, type DbChat, type DbDialog, type DbMember, type DbSpace, type DbUser } from "@in/server/db/schema"
import { UsersModel } from "@in/server/db/models/users"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { FunctionContext } from "@in/server/functions/_types"
import {
  Member_Role,
  Update,
  type InviteToSpaceInput,
  type InviteToSpaceResult,
  type Member,
  type User,
} from "@in/protocol/core"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { isValidEmail, isValidPhoneNumber, isValidSpaceId } from "@in/server/utils/validate"
import { Authorize } from "@in/server/utils/authorize"
import { MembersModel } from "@in/server/db/models/members"
import { ProtocolConvertors } from "@in/server/types/protocolConvertors"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { ChatModel } from "@in/server/db/models/chats"
import { sendEmail } from "@in/server/utils/email"
import { SpaceModel } from "@in/server/db/models/spaces"
import { Notifications } from "@in/server/modules/notifications/notifications"
import { getCachedUserName } from "@in/server/modules/cache/userNames"
import { Log } from "@in/server/utils/log"
import { getUpdateGroup, getUpdateGroupForSpace } from "@in/server/modules/updates"
import { RealtimeUpdates } from "@in/server/realtime/message"

const log = new Log("space.inviteToSpace")

export const inviteToSpace = async (
  input: InviteToSpaceInput,
  context: FunctionContext,
): Promise<InviteToSpaceResult> => {
  const spaceId = Number(input.spaceId)
  if (!isValidSpaceId(spaceId)) {
    throw RealtimeRpcError.BadRequest
  }

  // Get space
  const space = await SpaceModel.getSpaceById(spaceId)

  if (!space) {
    throw RealtimeRpcError.SpaceIdInvalid
  }

  // Validate our permission in this space and maximum role we can assign
  const { member: ourMembership } = await Authorize.spaceMember(spaceId, context.currentUserId)

  if (ourMembership.role === "member" && input.role != Member_Role.MEMBER) {
    throw RealtimeRpcError.SpaceAdminRequired
  }

  if (ourMembership.role !== "owner" && input.role == Member_Role.OWNER) {
    throw RealtimeRpcError.SpaceOwnerRequired
  }

  let inviteInfo: InviteInfo

  // Determine method
  switch (input.via.oneofKind) {
    case "userId":
      inviteInfo = await inviteViaUserId(spaceId, Number(input.via.userId), input, context)
      break

    case "email":
      inviteInfo = await inviteViaEmail(spaceId, input.via.email, input, context)
      break

    case "phoneNumber":
      inviteInfo = await inviteViaPhoneNumber(spaceId, input.via.phoneNumber, input, context)
      break

    default:
      throw RealtimeRpcError.BadRequest
  }

  // Create member and chat
  let member = await createMember(spaceId, inviteInfo.user.id, input, context)
  let { chat, dialog } = await createChat(inviteInfo.user.id, context)

  // Send invite
  sendInvite(inviteInfo.user, space, input, context)
    .then(() => {
      log.info("Invite sent", { spaceId, userId: inviteInfo.user.id })
    })
    .catch((error) => {
      log.error(error, "Failed to send invite", { spaceId, userId: inviteInfo.user.id })
    })

  // Send updates
  pushUpdateForInvitedUser({ space, member, inviteUserId: inviteInfo.user.id })
  pushUpdatesForSpace({ spaceId, member, user: inviteInfo.user, currentUserId: context.currentUserId })

  return {
    user: Encoders.user({ user: inviteInfo.user, min: false }),
    member: Encoders.member(member),
    chat: Encoders.chat(chat),
    dialog: Encoders.dialog(dialog, { unreadCount: 0 }),
  }
}

type InviteInfo = {
  user: DbUser
}

// ------------------------------------------------------------

async function inviteViaUserId(
  spaceId: number,
  userId: number,
  input: InviteToSpaceInput,
  context: FunctionContext,
): Promise<InviteInfo> {
  // Validate user
  const user = await UsersModel.getUserById(userId)
  if (!user) {
    throw RealtimeRpcError.UserIdInvalid
  }
  return { user }
}

async function inviteViaEmail(
  spaceId: number,
  email: string,
  input: InviteToSpaceInput,
  context: FunctionContext,
): Promise<InviteInfo> {
  // Validate email
  if (!isValidEmail(email)) {
    throw RealtimeRpcError.EmailInvalid
  }

  // Check if already a user
  let user = await UsersModel.getUserByEmail(email)

  if (!user) {
    // If no user, create one
    user = await UsersModel.createUserWhenInvited({ email })
  }

  return { user }
}

async function inviteViaPhoneNumber(
  spaceId: number,
  phoneNumber: string,
  input: InviteToSpaceInput,
  context: FunctionContext,
): Promise<InviteInfo> {
  // Check if already a user
  let user = await UsersModel.getUserByPhoneNumber(phoneNumber)

  if (!user) {
    // If no user, create one
    user = await UsersModel.createUserWhenInvited({ phoneNumber })
  }

  return { user }
}

// ------------------------------------------------------------

async function createMember(
  spaceId: number,
  userId: number,
  input: InviteToSpaceInput,
  context: FunctionContext,
): Promise<DbMember> {
  // Check if already a member
  const member = await MembersModel.getMemberByUserId(spaceId, userId)

  if (member) {
    throw RealtimeRpcError.UserAlreadyMember
  }

  // Create member
  const newMember = await MembersModel.createMember(
    spaceId,
    userId,
    ProtocolConvertors.protocolMemberRoleToDb(input.role),
    { invitedBy: context.currentUserId },
  )

  // Return result
  return newMember
}

async function createChat(userId: number, context: FunctionContext): Promise<{ chat: DbChat; dialog: DbDialog }> {
  // Create chat
  const { chat, dialog } = await ChatModel.createUserChatAndDialog({
    peerUserId: userId,
    currentUserId: context.currentUserId,
  })

  // Return result
  return { chat, dialog }
}

async function sendInvite(user: DbUser, space: DbSpace, input: InviteToSpaceInput, context: FunctionContext) {
  const userName = await getCachedUserName(user.id)

  // Send invite to email or via push notification
  if (user.email) {
    await sendEmail({
      to: user.email,
      content: {
        template: "invitedToSpace",
        variables: {
          email: user.email,
          spaceName: space?.name ?? "Unnamed Space",
          isExistingUser: user.pendingSetup ?? false,
          firstName: user.firstName ?? undefined,
          invitedByUserName: userName,
        },
      },
    })
  }

  if (!user.pendingSetup) {
    let inviterName = userName?.firstName ?? (userName?.username ? `@${userName.username}` : userName?.email)

    // Now send push notification
    await Notifications.sendToUser({
      userId: user.id,
      senderUserId: context.currentUserId,
      threadId: `invite_${space.id}`,
      title: `${inviterName ?? "Someone"} added you to "${space?.name ?? "Unnamed"}" space`,
      body: `Open the app, tap on the space name to start chatting.`,
    })
  }
}

// ------------------------------------------------------------
// Updates

const pushUpdateForInvitedUser = async ({
  space,
  member,
  inviteUserId,
}: {
  inviteUserId: number
  space: DbSpace
  member: DbMember
}) => {
  // Update for the person who was invited
  const update: Update = {
    update: {
      oneofKind: "joinSpace",
      joinSpace: {
        space: Encoders.space(space),
        member: Encoders.member(member),
      },
    },
  }

  RealtimeUpdates.pushToUser(inviteUserId, [update])
}

const pushUpdatesForSpace = async ({
  spaceId,
  member,
  user,
  currentUserId,
}: {
  spaceId: number
  member: DbMember
  user: DbUser
  currentUserId: number
}) => {
  const update: Update = {
    update: {
      oneofKind: "spaceMemberAdd",
      spaceMemberAdd: {
        member: Encoders.member(member),
        user: Encoders.user({ user, min: false }),
      },
    },
  }

  // Update for the space
  const updateGroup = await getUpdateGroupForSpace(spaceId, { currentUserId })

  updateGroup.userIds.forEach((userId) => {
    RealtimeUpdates.pushToUser(userId, [update])
  })
}
