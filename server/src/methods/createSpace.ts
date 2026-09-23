import { chatTitleFields } from "@in/server/modules/encryption/chatTitleStorage"
import type { HandlerContext } from "@in/server/controllers/helpers"
import { db } from "@in/server/db"
import type { UpdateSeqAndDate } from "@in/server/db/models/updates"
import { chats, members, spaces, users } from "@in/server/db/schema"
import {
  encodeChatInfo,
  encodeDialogInfo,
  encodeMemberInfo,
  encodeSpaceInfo,
  TChatInfo,
  TDialogInfo,
  TMemberInfo,
  TSpaceInfo,
} from "@in/server/api-types"
import { InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { Type } from "@sinclair/typebox"
import type { Static } from "elysia"
import { BotAlerts } from "@in/server/modules/bot-events/alerts"
import { activateCommittedSpaceMembership } from "@in/server/modules/authorization/spaceMembershipLifecycle"
import {
  getPublicHandleAvailability,
  isSpaceHandleUniqueError,
  lockPublicHandleNamespace,
  normalizeSpaceHandle,
} from "@in/server/modules/spaces/spaceHandle"
import { allocateThreadNumber } from "@in/server/modules/threadNumbers"
import { UserBucketUpdates } from "@in/server/modules/updates/userBucketUpdates"
import {
  liveUpdateForPersistedUserChatOpenProjection,
  persistPrimarySpaceChatOpenProjectionInTransaction,
  type PersistedUserChatOpenProjection,
} from "@in/server/modules/updates/userChatOpenProjection"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { RealtimeUpdates } from "@in/server/realtime/message"
import type { Update } from "@inline-chat/protocol/core"
import { eq } from "drizzle-orm"
import { requireOwnedSpacePhoto } from "@in/server/modules/spaces/spacePhoto"

export const Input = Type.Object({
  name: Type.String(),
  photoFileUniqueId: Type.Optional(Type.String()),
  handle: Type.Optional(Type.String()),
})

export const Response = Type.Object({
  space: TSpaceInfo,
  member: TMemberInfo,
  chats: Type.Array(TChatInfo),
  dialogs: Type.Array(TDialogInfo),
})

export const handler = async (
  input: Static<typeof Input>,
  context: HandlerContext,
): Promise<Static<typeof Response>> => {
  const photoFileUniqueId = await requireOwnedSpacePhoto(input.photoFileUniqueId, context.currentUserId)
  const handle = input.handle === undefined ? null : normalizeSpaceHandle(input.handle)
  if (input.handle !== undefined && !handle) {
    throw new InlineError(InlineError.ApiError.USERNAME_INVALID)
  }

  try {
    const { space, member, mainChat, chatOpen, joinUpdate, accessUpdate } = await db.transaction(async (tx) => {
      if (handle) {
        await lockPublicHandleNamespace(tx, handle)
        const availability = await getPublicHandleAvailability(tx, handle)
        if (availability !== "available") {
          throw new InlineError(InlineError.ApiError.USERNAME_TAKEN)
        }
      }

      const [creator] = await tx
        .select({ id: users.id, deleted: users.deleted })
        .from(users)
        .where(eq(users.id, context.currentUserId))
        .for("update")
        .limit(1)
      if (!creator || creator.deleted === true) {
        throw new InlineError(InlineError.ApiError.USER_DEACTIVATED)
      }

      const [space] = await tx
        .insert(spaces)
        .values({
          name: input.name,
          photoFileUniqueId,
          handle,
          creatorId: context.currentUserId,
        })
        .returning()

      if (!space) {
        throw new InlineError(InlineError.ApiError.INTERNAL)
      }

      const [member] = await tx
        .insert(members)
        .values({
          spaceId: space.id,
          userId: context.currentUserId,
          role: "owner",
          date: new Date(),
        })
        .returning()

      if (!member) {
        throw new InlineError(InlineError.ApiError.INTERNAL)
      }

      const threadNumber = await allocateThreadNumber(tx, { type: "space", id: space.id })
      const [mainChat] = await tx
        .insert(chats)
        .values({
          spaceId: space.id,
          type: "thread",
          ...chatTitleFields(space.name, { spaceId: space.id }),
          publicThread: true,
          description: "Main chat for everyone in the space",
          threadNumber,
          date: new Date(),
        })
        .returning()

      if (!mainChat) {
        throw new InlineError(InlineError.ApiError.INTERNAL)
      }

      const joinUpdate = await UserBucketUpdates.enqueue(
        {
          userId: context.currentUserId,
          update: {
            oneofKind: "userJoinSpace",
            userJoinSpace: {
              space: Encoders.space(space, { encodingForUserId: context.currentUserId }),
              member: Encoders.member(member),
            },
          },
        },
        { tx },
      )
      const accessUpdate = await UserBucketUpdates.enqueue(
        {
          userId: context.currentUserId,
          update: {
            oneofKind: "userAddedToChat",
            userAddedToChat: { chatId: BigInt(mainChat.id) },
          },
        },
        { tx },
      )
      const chatOpen = await persistPrimarySpaceChatOpenProjectionInTransaction(tx, {
        spaceId: space.id,
        userId: context.currentUserId,
        canAccessPublicChats: true,
        persistWhenUnchanged: true,
      })
      if (!chatOpen) {
        throw new InlineError(InlineError.ApiError.INTERNAL)
      }

      return { space, member, mainChat, chatOpen, joinUpdate, accessUpdate }
    })

    try {
      await activateCommittedSpaceMembership({
        spaceId: space.id,
        userId: context.currentUserId,
        memberId: member.id,
      }, () => {
        pushCreatedSpaceUserUpdates({
          userId: context.currentUserId,
          space,
          member,
          mainChatId: mainChat.id,
          joinUpdate,
          accessUpdate,
          chatOpen,
        })
        return undefined
      })
    } catch (error: unknown) {
      Log.shared.error("Failed to activate created space projection", { spaceId: space.id, error })
    }

    // Best-effort internal alert (should never affect the user action).
    BotAlerts.spaceCreated({
      creatorUserId: context.currentUserId,
      spaceId: space.id,
      spaceName: space.name,
      handle: space.handle,
    })

    const output = { space, member, chats: [mainChat], dialogs: [chatOpen.dialogRow] }
    return {
      space: encodeSpaceInfo(output.space, { currentUserId: context.currentUserId }),
      member: encodeMemberInfo(output.member),
      chats: output.chats
        .map((c) => c && encodeChatInfo(c, { currentUserId: context.currentUserId }))
        .filter((c) => c !== undefined),
      dialogs: output.dialogs
        .map((d) => d && encodeDialogInfo({ ...d, unreadCount: 0 }))
        .filter((d) => d !== undefined),
    }
  } catch (error) {
    if (error instanceof InlineError) {
      throw error
    }
    if (isSpaceHandleUniqueError(error)) {
      throw new InlineError(InlineError.ApiError.USERNAME_TAKEN)
    }
    Log.shared.error("Failed to create space", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}

function pushCreatedSpaceUserUpdates(input: {
  userId: number
  space: typeof spaces.$inferSelect
  member: typeof members.$inferSelect
  mainChatId: number
  joinUpdate: UpdateSeqAndDate
  accessUpdate: UpdateSeqAndDate
  chatOpen: PersistedUserChatOpenProjection
}): void {
  const updates: Update[] = [
    {
      seq: input.joinUpdate.seq,
      date: encodeDateStrict(input.joinUpdate.date),
      update: {
        oneofKind: "joinSpace",
        joinSpace: {
          space: Encoders.space(input.space, { encodingForUserId: input.userId }),
          member: Encoders.member(input.member),
        },
      },
    },
    {
      seq: input.accessUpdate.seq,
      date: encodeDateStrict(input.accessUpdate.date),
      update: {
        oneofKind: "userAddedToChat",
        userAddedToChat: { chatId: BigInt(input.mainChatId) },
      },
    },
    liveUpdateForPersistedUserChatOpenProjection(input.chatOpen),
  ]

  void RealtimeUpdates.pushToUser(input.userId, updates).catch((error: unknown) => {
    Log.shared.warn("Failed to publish created Space projection", { spaceId: input.space.id, userId: input.userId, error })
  })
}
