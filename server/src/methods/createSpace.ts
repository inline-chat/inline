import type { HandlerContext } from "@in/server/controllers/helpers"
import { db } from "@in/server/db"
import { chats, members, spaces } from "@in/server/db/schema"
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
import {
  getPublicHandleAvailability,
  isSpaceHandleUniqueError,
  lockPublicHandleNamespace,
  normalizeSpaceHandle,
} from "@in/server/modules/spaces/spaceHandle"
import { setDialogOpenForUsers } from "@in/server/modules/dialogOpen"
import { allocateThreadNumber } from "@in/server/modules/threadNumbers"

export const Input = Type.Object({
  name: Type.String(),
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
  const handle = input.handle === undefined ? null : normalizeSpaceHandle(input.handle)
  if (input.handle !== undefined && !handle) {
    throw new InlineError(InlineError.ApiError.USERNAME_INVALID)
  }

  try {
    const { space, member, mainChat } = await db.transaction(async (tx) => {
      if (handle) {
        await lockPublicHandleNamespace(tx, handle)
        const availability = await getPublicHandleAvailability(tx, handle)
        if (availability === "taken") {
          throw new InlineError(InlineError.ApiError.USERNAME_TAKEN)
        }
      }

      const [space] = await tx
        .insert(spaces)
        .values({
          name: input.name,
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
          title: space.name,
          publicThread: true,
          description: "Main chat for everyone in the space",
          threadNumber,
          date: new Date(),
        })
        .returning()

      if (!mainChat) {
        throw new InlineError(InlineError.ApiError.INTERNAL)
      }

      return { space, member, mainChat }
    })

    const { dialogs: openedDialogs } = await setDialogOpenForUsers({
      chat: mainChat,
      userIds: [context.currentUserId],
      open: true,
      showInChatList: true,
    })
    const newDialog = openedDialogs.find((dialog) => dialog.userId === context.currentUserId)
    if (!newDialog) {
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    // Best-effort internal alert (should never affect the user action).
    BotAlerts.spaceCreated({
      creatorUserId: context.currentUserId,
      spaceId: space.id,
      spaceName: space.name,
      handle: space.handle,
    })

    const output = { space, member, chats: [mainChat], dialogs: [newDialog] }
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
