import { db } from "@in/server/db"
import { eq, inArray, and, or } from "drizzle-orm"
import { chats, members, spaces, dialogs } from "@in/server/db/schema"
import { ErrorCodes, InlineError } from "@in/server/types/errors"
import { Log } from "@in/server/utils/log"
import { type Static, Type } from "@sinclair/typebox"
import {
  encodeChatInfo,
  encodeMemberInfo,
  encodeSpaceInfo,
  encodeDialogInfo,
  TChatInfo,
  TMemberInfo,
  TSpaceInfo,
  TDialogInfo,
} from "@in/server/api-types"
import { TInputId } from "@in/server/types/methods"
import { Authorize } from "../utils/authorize"
import { DialogsModel } from "@in/server/db/models/dialogs"

export const Input = Type.Object({
  id: TInputId,
})

type Input = Static<typeof Input>

type Context = {
  currentUserId: number
}

export const Response = Type.Object({
  space: TSpaceInfo,
  members: Type.Array(TMemberInfo),
  // chats: Type.Array(TChatInfo),
  // dialogs: Type.Array(TDialogInfo),
})

type Response = Static<typeof Response>

export const handler = async (input: Input, context: Context): Promise<Response> => {
  try {
    const spaceId = Number(input.id)
    if (isNaN(spaceId)) {
      throw new InlineError(InlineError.ApiError.BAD_REQUEST)
    }

    // Check if current user is a member of the space
    await Authorize.spaceMember(spaceId, context.currentUserId)

    const spaceResult = await db.select().from(spaces).where(eq(spaces.id, spaceId)).limit(1)

    if (!spaceResult[0]) {
      throw new InlineError(InlineError.ApiError.INTERNAL)
    }

    const membersResult = await db.select().from(members).where(eq(members.spaceId, spaceId))

    //const chatsResult = await db.select().from(chats).where(eq(chats.spaceId, spaceId))

    // Get members dialogs
    // const dialogsResult = await db
    //   .select()
    //   .from(dialogs)
    //   .where(
    //     or(
    //       and(
    //         eq(dialogs.userId, context.currentUserId),
    //         inArray(
    //           dialogs.peerUserId,
    //           membersResult.map((m) => m.userId),
    //         ),
    //       ),
    //       and(
    //         eq(dialogs.peerUserId, context.currentUserId),
    //         inArray(
    //           dialogs.userId,
    //           membersResult.map((m) => m.userId),
    //         ),
    //       ),
    //     ),
    //   )

    // const existingDialogPeerIds = dialogsResult.map((d) =>
    //   d.userId === context.currentUserId ? d.peerUserId : d.userId,
    // )

    // Get members without dialogs
    // const membersWithoutDialogs = membersResult
    //   .filter((m) => m.userId !== context.currentUserId)
    //   .filter((m) => !existingDialogPeerIds.includes(m.userId))

    // Create dialogs for members without dialogs
    // const newDialogs = membersWithoutDialogs.map((member) => {
    //   const dialogId = member.userId
    //   return {
    //     id: dialogId,
    //     draft: null,
    //     date: new Date(),
    //     userId: context.currentUserId,
    //     peerUserId: member.userId,
    //     spaceId: null,
    //     pinned: false,
    //     unreadCount: 0,
    //     readInboxMaxId: null,
    //     readOutboxMaxId: null,
    //     chatId: dialogId,
    //     archived: false,
    //   }
    // })

    // Pack dialogs to encode
    // const allDialogs = [...dialogsResult, ...newDialogs]

    // const dialogsUnreads = await DialogsModel.getBatchUnreadCounts({
    //   userId: context.currentUserId,
    //   chatIds: allDialogs.map((d) => d.chatId),
    // })

    // const dialogsEncoded = allDialogs.map((dialog) => {
    //   const unreadCount = dialogsUnreads.find((uc) => uc.chatId === dialog.chatId)?.unreadCount ?? 0
    //   return encodeDialogInfo({ ...dialog, unreadCount })
    // })

    return {
      space: encodeSpaceInfo(spaceResult[0], { currentUserId: context.currentUserId }),
      members: membersResult.map((member) => encodeMemberInfo(member)),
      // chats: chatsResult.map((chat) => encodeChatInfo(chat, { currentUserId: context.currentUserId })),
      // dialogs: dialogsEncoded,
    }
  } catch (error) {
    Log.shared.error("Failed to get space", error)
    throw new InlineError(InlineError.ApiError.INTERNAL)
  }
}
