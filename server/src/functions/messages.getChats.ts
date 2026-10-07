import type { Chat, Dialog, DialogFolder, GetChatsInput, Message, Space, User } from "@inline-chat/protocol/core"
import { MessageModel } from "@in/server/db/models/messages"
import type { FunctionContext } from "@in/server/functions/_types"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { Log } from "@in/server/utils/log"
import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { withHistoryReadSnapshot } from "@in/server/modules/message/historySnapshot"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { and, eq, inArray, isNull, or, sql } from "drizzle-orm"
import {
  chatParticipantGroups,
  chats,
  dialogs,
  spaces,
  members,
  userGroupMembers,
  userGroups,
  userNotDeleted,
  users,
  type DbSpace,
  type DbChat,
  type DbDialog,
  type DbNewDialog,
  type DbUser,
  type DbFile,
} from "@in/server/db/schema"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { encodePeerFromChat } from "@in/server/realtime/encoders/encodePeer"
import { dialogOpenDefaultsForChat } from "@in/server/modules/dialogOpen"
import { getDialogFolders } from "@in/server/modules/dialogFolders"
import { getEffectiveChatAccessUserIds } from "@in/server/modules/authorization/chatAccessProjection"
import { getMessageThreadProjectionsByParent } from "@in/server/modules/subthreads"

type Input = GetChatsInput

type Output = {
  chats: Chat[]
  dialogs: Dialog[]
  spaces: Space[]
  users: User[]
  messages: Message[]
  folders: DialogFolder[]
}

const log = new Log("functions.getChats")

// Discover candidates through scoped roots or explicit target grants, never by
// scanning every home subthread. The access projection below remains the sole
// authority for what may be returned, including retained grants after revocation.
async function getCompleteCatalogChatIds(currentUserId: number, query: Pick<typeof db, "execute">): Promise<number[]> {
  const rows = await query.execute<{ chatId: number }>(sql`
    with recursive seeds as (
      select c.id
      from chats c
      where c.parent_chat_id is null
        and (
          (c.type = 'private' and (c.min_user_id = ${currentUserId} or c.max_user_id = ${currentUserId}))
          or (c.type = 'thread' and exists (
            select 1 from members m
            where m.space_id = c.space_id and m.user_id = ${currentUserId}
          ))
        )

      union

      select cp.chat_id
      from chat_participants cp
      join chats c on c.id = cp.chat_id
      where cp.user_id = ${currentUserId} and c.type = 'thread'

      union

      select cpg.chat_id
      from chat_participant_groups cpg
      join user_group_members ugm on ugm.group_id = cpg.group_id
      join chats c on c.id = cpg.chat_id
      where ugm.user_id = ${currentUserId} and c.type = 'thread'
    ), catalog as (
      select id from seeds

      union

      select child.id from chats child join catalog parent on child.parent_chat_id = parent.id
      where child.type = 'thread'
    )
    select id as "chatId" from catalog order by id
  `)
  return rows.map((row) => row.chatId)
}

async function ensurePrivateChatsForSpaceMembers(currentUserId: number): Promise<void> {
  try {
    const allMembers = await db
      .selectDistinct({ userId: members.userId })
      .from(members)
      .innerJoin(spaces, eq(members.spaceId, spaces.id))
      .where(
        and(
          inArray(
            members.spaceId,
            db.select({ spaceId: members.spaceId }).from(members).where(eq(members.userId, currentUserId)),
          ),
          isNull(spaces.deleted),
        ),
      )

    const otherUserIds = allMembers.map((m) => m.userId).filter((id) => id !== currentUserId)

    if (otherUserIds.length === 0) return

    const chatPairs = otherUserIds.map((userId) => ({
      minUserId: Math.min(currentUserId, userId),
      maxUserId: Math.max(currentUserId, userId),
    }))

    const existingChats = await db
      .select({ id: chats.id, type: chats.type, minUserId: chats.minUserId, maxUserId: chats.maxUserId })
      .from(chats)
      .where(and(eq(chats.type, "private"), or(eq(chats.minUserId, currentUserId), eq(chats.maxUserId, currentUserId))))

    const existingChatSet = new Set(existingChats.map((c) => `${c.minUserId}-${c.maxUserId}`))

    const missingChatPairs = chatPairs.filter((pair) => !existingChatSet.has(`${pair.minUserId}-${pair.maxUserId}`))

    let newChats: typeof existingChats = []
    if (missingChatPairs.length > 0) {
      newChats = await db
        .insert(chats)
        .values(
          missingChatPairs.map((pair) => ({
            type: "private" as const,
            minUserId: pair.minUserId,
            maxUserId: pair.maxUserId,
          })),
        )
        .onConflictDoNothing()
        .returning()
    }

    const allChatsToProcess = [...existingChats, ...newChats]

    if (allChatsToProcess.length === 0) return

    const existingDialogs = await db
      .select({ chatId: dialogs.chatId, userId: dialogs.userId })
      .from(dialogs)
      .where(
        inArray(
          dialogs.chatId,
          allChatsToProcess.map((c) => c.id),
        ),
      )

    const existingDialogSet = new Set(existingDialogs.map((d) => `${d.chatId}-${d.userId}`))

    const dialogsToCreate: DbNewDialog[] = []

    for (const chat of allChatsToProcess) {
      if (chat.minUserId === null || chat.maxUserId === null) {
        continue
      }

      if (!existingDialogSet.has(`${chat.id}-${currentUserId}`)) {
        dialogsToCreate.push({
          chatId: chat.id,
          userId: currentUserId,
          peerUserId: chat.minUserId === currentUserId ? chat.maxUserId : chat.minUserId,
          ...dialogOpenDefaultsForChat({ type: "private" }),
        })
      }

      const otherUserId = chat.minUserId === currentUserId ? chat.maxUserId : chat.minUserId
      if (!existingDialogSet.has(`${chat.id}-${otherUserId}`)) {
        dialogsToCreate.push({
          chatId: chat.id,
          userId: otherUserId,
          peerUserId: currentUserId,
          ...dialogOpenDefaultsForChat({ type: "private" }),
        })
      }
    }

    if (dialogsToCreate.length > 0) {
      await db.insert(dialogs).values(dialogsToCreate).onConflictDoNothing()
    }
  } catch (error) {
    log.error("Failed to ensure private chats for space members", { currentUserId, error })
  }
}

type CatalogWhere = NonNullable<NonNullable<Parameters<typeof db.query.chats.findMany>[0]>["where"]>

async function getCatalogWhere(
  currentUserId: number,
  includeSubthreads: boolean,
  query: typeof db | Transaction,
): Promise<CatalogWhere> {
  const completeCatalogIds = includeSubthreads ? await getCompleteCatalogChatIds(currentUserId, query) : undefined
  return completeCatalogIds === undefined
    ? {
        OR: [
          // DMs
          {
            type: "private",
            // that are between this user and another user
            OR: [
              {
                minUserId: currentUserId,
              },
              {
                maxUserId: currentUserId,
              },
            ],
          },

          // Public threads
          {
            type: "thread",
            parentChatId: {
              isNull: true,
            },
            publicThread: true,
            // that we are a participant in
            space: {
              deleted: {
                isNull: true,
              },
              members: {
                user: {
                  id: currentUserId,
                },
                // only include public chats if user has access to them
                canAccessPublicChats: true,
              },
            },
          },

          // Private threads
          {
            type: "thread",
            parentChatId: {
              isNull: true,
            },
            publicThread: false,
            // that we are a participant in
            participants: {
              user: {
                id: currentUserId,
              },
            },
            // extra safety check until we clean up our database so if it's removed from space we remove from participants
            space: {
              deleted: {
                isNull: true,
              },
              members: {
                user: {
                  id: currentUserId,
                },
              },
            },
          },

          // Private threads granted through one of the user's groups. Keep this correlated with
          // the main fetch so a concurrent revocation cannot leak a stale discovery result.
          {
            type: "thread",
            parentChatId: {
              isNull: true,
            },
            publicThread: false,
            space: {
              deleted: {
                isNull: true,
              },
              members: {
                user: {
                  id: currentUserId,
                },
              },
            },
            RAW: (chat, { exists }) =>
              exists(
                query
                  .select({ id: chatParticipantGroups.id })
                  .from(chatParticipantGroups)
                  .innerJoin(userGroups, eq(userGroups.id, chatParticipantGroups.groupId))
                  .innerJoin(userGroupMembers, eq(userGroupMembers.groupId, userGroups.id))
                  .innerJoin(
                    members,
                    and(eq(members.spaceId, userGroups.spaceId), eq(members.userId, userGroupMembers.userId)),
                  )
                  .innerJoin(users, eq(users.id, userGroupMembers.userId))
                  .where(
                    and(
                      eq(chatParticipantGroups.chatId, chat.id),
                      eq(userGroups.spaceId, chat.spaceId),
                      eq(userGroupMembers.userId, currentUserId),
                      userNotDeleted(),
                    ),
                  ),
              ),
          },

          // Home threads (non-space)
          {
            type: "thread",
            parentChatId: {
              isNull: true,
            },
            publicThread: false,
            spaceId: {
              isNull: true,
            },
            participants: {
              user: {
                id: currentUserId,
              },
            },
          },

          // Linked subthreads only surface once a dialog exists for this user.
          {
            type: "thread",
            parentChatId: {
              isNotNull: true,
            },
            dialogs: {
              userId: currentUserId,
              OR: [{ chatListHidden: false }, { chatListHidden: { isNull: true } }],
            },
          },
        ],
      }
    : { id: { in: completeCatalogIds } }
}

// Dialog creation remains a preparation step. Response data is re-read and
// reauthorized later inside the read-only snapshot, including concurrent winners.
async function prepareCatalogDialogs(input: Input, currentUserId: number): Promise<void> {
  const candidates = await db.query.chats.findMany({
    columns: { id: true, type: true, minUserId: true, maxUserId: true, spaceId: true },
    where: {
      AND: [
        await getCatalogWhere(currentUserId, input.includeSubthreads === true, db),
        {
          parentChatId: { isNull: true },
          RAW: (chat, { not, exists }) =>
            not(
              exists(
                db
                  .select({ id: dialogs.id })
                  .from(dialogs)
                  .where(and(eq(dialogs.chatId, chat.id), eq(dialogs.userId, currentUserId))),
              ),
            ),
        },
      ],
    },
  })
  if (candidates.length === 0) return
  const access = await getEffectiveChatAccessUserIds(
    db,
    candidates.map((chat) => chat.id),
    {
      userIds: [currentUserId],
    },
  )
  const missing = candidates.filter((chat) => access.get(chat.id)?.has(currentUserId))
  if (missing.length === 0) return
  await db
    .insert(dialogs)
    .values(
      missing.map((chat) => ({
        chatId: chat.id,
        userId: currentUserId,
        peerUserId:
          chat.type === "private" ? (chat.minUserId === currentUserId ? chat.maxUserId : chat.minUserId) : null,
        spaceId: chat.type === "thread" ? chat.spaceId : null,
        ...dialogOpenDefaultsForChat(chat),
      })),
    )
    .onConflictDoNothing({ target: [dialogs.chatId, dialogs.userId] })
}

export const getChats = async (input: Input, context: FunctionContext): Promise<Output> => {
  const currentUserId = context.currentUserId
  await prepareCatalogDialogs(input, currentUserId)
  return withHistoryReadSnapshot(async (tx) => {
    const foldersList = await getDialogFolders(currentUserId, tx)

    // TEMPORARY UNTIL getChats is integrated into the clients
    // TODO: DELETE ONCE getChats is integrated into the clients) also remove the tests
    // await ensurePrivateChatsForSpaceMembers(currentUserId)

    // Buckets for results
    let dialogsList: DbDialog[] = []
    let usersList: (DbUser & { photoFile?: DbFile | null })[] = []
    let chatsList: DbChat[] = []
    let messagesList: Message[] = []
    let spacesList: DbSpace[] = []

    // // 1. Get all spaces the user is a part of
    const userSpaces = await tx.query.spaces.findMany({
      where: {
        members: {
          user: {
            id: currentUserId,
          },
        },
        deleted: {
          isNull: true,
        },
      },
    })
    spacesList = userSpaces

    // Fetch a list of public threads the user is a part of and don't have a dialog
    const candidates = await tx.query.chats.findMany({
      where: await getCatalogWhere(currentUserId, input.includeSubthreads === true, tx),

      with: {
        // dialogs for this user
        dialogs: {
          where: {
            userId: currentUserId,
          },

          with: {
            peerUser: {
              with: {
                photoFile: true,
              },
            },
          },
        },

        lastMsg: {
          with: {
            from: {
              with: {
                photoFile: true,
              },
            },
            file: true,
            photo: {
              with: {
                photoSizes: {
                  with: {
                    file: true,
                  },
                },
              },
            },
            video: {
              with: {
                file: true,
                photo: {
                  with: {
                    photoSizes: {
                      with: {
                        file: true,
                      },
                    },
                  },
                },
              },
            },
            document: {
              with: {
                file: true,
                photo: {
                  with: {
                    photoSizes: {
                      with: {
                        file: true,
                      },
                    },
                  },
                },
              },
            },
            voice: { with: { file: true } },
            blockContent: true,
            reactions: true,
          },
        },
      },
    })

    // Discovery is not authorization. Check every candidate against this exact
    // catalog snapshot before exposing its metadata, previews or senders.
    const chatAccess = await getEffectiveChatAccessUserIds(
      tx,
      candidates.map((chat) => chat.id),
      {
        userIds: [currentUserId],
      },
    )
    const chats = candidates.filter((chat) => chatAccess.get(chat.id)?.has(currentUserId) === true)

    const processedLastMessages = await MessageModel.processMessages(
      chats.flatMap((chat) => (chat.lastMsg ? [chat.lastMsg] : [])),
      tx,
    )
    const processedLastMessagesByGlobalId = new Map(processedLastMessages.map((message) => [message.globalId, message]))
    const threadProjectionsByParent = await getMessageThreadProjectionsByParent({
      parentMessages: chats.flatMap((chat) =>
        chat.lastMsgId == null
          ? []
          : [
              {
                chatId: chat.id,
                messageId: chat.lastMsgId,
              },
            ],
      ),
      userId: currentUserId,
      tx,
    })

    // Add chats to results
    const messagesByKey = new Map<string, Message>()
    const missingLastMsgKeys: { chatId: number; messageId: number }[] = []
    chats.forEach((chat) => {
      // chat
      chatsList.push(chat)

      // last message
      if (chat.lastMsg) {
        const processedMsg = processedLastMessagesByGlobalId.get(chat.lastMsg.globalId)
        if (processedMsg) {
          const threadProjection = threadProjectionsByParent.get(chat.id)?.get(processedMsg.messageId)
          const encodedMsg = Encoders.fullMessage({
            message: processedMsg,
            encodingForUserId: currentUserId,
            encodingForPeer: { inputPeer: encodePeerFromChat(chat, { currentUserId }) },
            replies: threadProjection?.replies,
            subthread: threadProjection?.subthread,
          })
          messagesByKey.set(`${chat.id}:${processedMsg.messageId}`, encodedMsg)
        } else if (chat.lastMsgId) {
          missingLastMsgKeys.push({ chatId: chat.id, messageId: chat.lastMsgId })
        }

        // sender
        if (chat.lastMsg.from) {
          usersList.push(chat.lastMsg.from)
        }
      } else if (chat.lastMsgId) {
        // Should be rare (FK enforces validity), but keep the contract: if chat.lastMsgId is set,
        // GetChatsResult.messages must include that message so clients never need O(n) follow-up calls.
        missingLastMsgKeys.push({ chatId: chat.id, messageId: chat.lastMsgId })
      }

      if (chat.dialogs.length > 0) {
        let dialog = chat.dialogs[0]
        // dialog
        if (dialog) {
          dialogsList.push(dialog)
        }
        // peer user
        let peerUser = dialog?.peerUser
        if (peerUser) {
          usersList.push(peerUser)
        }
      }
    })

    if (missingLastMsgKeys.length > 0) {
      const messageIdsByChatId = new Map<number, bigint[]>()
      for (const key of missingLastMsgKeys) {
        let list = messageIdsByChatId.get(key.chatId)
        if (!list) {
          list = []
          messageIdsByChatId.set(key.chatId, list)
        }
        list.push(BigInt(key.messageId))
      }

      for (const [chatId, messageIds] of messageIdsByChatId) {
        const chat = chatsList.find((c) => c.id === chatId)
        if (!chat) continue

        const recovered = await MessageModel.getMessagesByIds(chatId, messageIds, { tx })
        if (recovered.length !== new Set(messageIds).size) throw RealtimeRpcError.InternalError()
        for (const msg of recovered) {
          const threadProjection = threadProjectionsByParent.get(chatId)?.get(msg.messageId)
          const encodedMsg = Encoders.fullMessage({
            message: msg,
            encodingForUserId: currentUserId,
            encodingForPeer: { inputPeer: encodePeerFromChat(chat, { currentUserId }) },
            replies: threadProjection?.replies,
            subthread: threadProjection?.subthread,
          })
          messagesByKey.set(`${chat.id}:${msg.messageId}`, encodedMsg)
          usersList.push(msg.from)
        }
      }
    }

    messagesList = Array.from(messagesByKey.values())

    // // 7. Get unread counts for all dialogs
    const unreadCounts = await DialogsModel.getBatchUnreadCounts({
      userId: currentUserId,
      chatIds: dialogsList.map((d) => d.chatId),
      tx,
    })

    // // 8. Encode everything to protocol buffer types
    const encodedDialogs = dialogsList.map((dialog) => {
      const unreadCount = unreadCounts.find((uc) => uc.chatId === dialog.chatId)?.unreadCount ?? 0
      return Encoders.dialog(dialog, { unreadCount })
    })

    const usersById = new Map<number, DbUser & { photoFile?: DbFile | null }>()
    for (const user of usersList) {
      const existing = usersById.get(user.id)
      if (!existing || (!existing.photoFile && user.photoFile)) {
        usersById.set(user.id, user)
      }
    }

    const encodedChats = await Encoders.chatsForUser(chatsList, { encodingForUserId: currentUserId, tx })
    const encodedSpaces = spacesList.map((space) => Encoders.space(space, { encodingForUserId: currentUserId }))
    const privateChatIds = new Set(chatsList.filter((chat) => chat.type === "private").map((chat) => chat.id))
    const dmPeerUserIds = new Set(
      dialogsList
        .filter((dialog) => privateChatIds.has(dialog.chatId))
        .flatMap((dialog) => (dialog.peerUserId === null ? [] : [dialog.peerUserId])),
    )
    const encodedUsers = Array.from(usersById.values()).map((user) =>
      Encoders.user({
        user,
        photoFile: user.photoFile ?? undefined,
        min: true,
        includeTimeZone: dmPeerUserIds.has(user.id),
        viewerUserId: currentUserId,
      }),
    )

    return {
      chats: encodedChats,
      dialogs: encodedDialogs,
      spaces: encodedSpaces,
      users: encodedUsers,
      messages: messagesList,
      folders: foldersList.map(Encoders.dialogFolder),
    }
  })
}

// export const getChats = async (input: Input, context: FunctionContext): Promise<Output> => {
//   const currentUserId = context.currentUserId

//   // Buckets for results
//   let usersList: (typeof users.$inferSelect)[] = []
//   let chatsList: (typeof chats.$inferSelect)[] = []
//   let messagesList: Message[] = []
//   let spacesList: DbSpace[] = []

//   // // 1. Get all spaces the user is a part of
//   const userSpaces = await db.query.spaces.findMany({
//     where: {
//       members: {
//         user: {
//           id: currentUserId,
//         },
//       },
//       deleted: {
//         isNull: true,
//       },
//     },
//   })
//   spacesList = userSpaces

//   // Fetch a list of public threads the user is a part of and don't have a dialog
//   const publicThreadsWithNoDialogs = await db.query.chats.findMany({
//     where: {
//       type: "thread",
//       publicThread: true,

//       // space threads
//       space: {
//         members: {
//           user: {
//             id: currentUserId,
//           },
//         },
//       },

//       NOT: {
//         dialogs: {
//           userId: currentUserId,
//         },
//       },
//     },
//   })

//   let chatsThatNeedDialogs: DbChat[] = [...publicThreadsWithNoDialogs]

//   // get private threads the user is a part of without dialogs
//   const privateThreadsWithNoDialogs = await db.query.chats.findMany({
//     where: {
//       type: "thread",
//       publicThread: false,

//       // that we are a participant in
//       participants: {
//         user: {
//           id: currentUserId,
//         },
//       },

//       // but don't have a dialog
//       NOT: {
//         dialogs: {
//           userId: currentUserId,
//         },
//       },
//     },
//   })

//   chatsThatNeedDialogs = [...chatsThatNeedDialogs, ...privateThreadsWithNoDialogs]

//   console.log("privateThreadsWithNoDialogs", privateThreadsWithNoDialogs)

//   // DMs without dialogs
//   const dmChatsWithoutDialogs = await db.query.chats.findMany({
//     where: {
//       type: "private",

//       // that are between the user and another user
//       OR: [
//         {
//           minUserId: currentUserId,
//         },
//         {
//           maxUserId: currentUserId,
//         },
//       ],

//       // that don't have a dialog
//       NOT: {
//         dialogs: {
//           userId: currentUserId,
//         },
//       },
//     },
//   })

//   chatsThatNeedDialogs = [...chatsThatNeedDialogs, ...dmChatsWithoutDialogs]

//   // Create dialog
//   if (chatsThatNeedDialogs.length > 0) {
//     await db.insert(dialogs).values(
//       chatsThatNeedDialogs.map((t) => ({
//         chatId: t.id,
//         userId: currentUserId,
//         // type-specific fields
//         peerUserId: t.type === "private" ? (t.minUserId === currentUserId ? t.maxUserId : t.minUserId) : null,
//         spaceId: t.type === "thread" ? t.spaceId : null,
//       })),
//     )
//   }

//   // Get all dialogs for the user
//   const userDialogs = await db.query.dialogs.findMany({
//     where: {
//       userId: currentUserId,
//     },
//     with: {
//       peerUser: true,

//       chat: {
//         with: {
//           lastMsg: {
//             with: {
//               from: true,
//               file: true,
//               photo: {
//                 with: {
//                   photoSizes: {
//                     with: {
//                       file: true,
//                     },
//                   },
//                 },
//               },
//               video: {
//                 with: {
//                   file: true,
//                   photo: {
//                     with: {
//                       photoSizes: {
//                         with: {
//                           file: true,
//                         },
//                       },
//                     },
//                   },
//                 },
//               },
//               document: {
//                 with: {
//                   file: true,
//                 },
//               },
//               reactions: true,
//               messageAttachments: {
//                 with: {
//                   externalTask: true,
//                   linkEmbed: {
//                     with: {
//                       photo: {
//                         with: {
//                           photoSizes: {
//                             with: {
//                               file: true,
//                             },
//                           },
//                         },
//                       },
//                     },
//                   },
//                 },
//               },
//             },
//           },
//         },
//       },
//     },
//   })

//   // // Add private chats to results
//   userDialogs.forEach((dialog) => {
//     if (dialog.chat) {
//       chatsList.push(dialog.chat)

//       if (dialog.chat.lastMsg) {
//         const processedMsg = MessageModel.processMessage(dialog.chat.lastMsg)
//         const encodedMsg = Encoders.fullMessage({
//           message: processedMsg,
//           encodingForUserId: currentUserId,
//           encodingForPeer: { inputPeer: encodePeerFromChat(dialog.chat, { currentUserId }) },
//         })
//         if (processedMsg) {
//           messagesList.push(encodedMsg)
//         }
//       }
//     }

//     if (dialog.peerUser) {
//       usersList.push(dialog.peerUser)
//     }
//   })

//   // // 7. Get unread counts for all dialogs
//   const unreadCounts = await DialogsModel.getBatchUnreadCounts({
//     userId: currentUserId,
//     chatIds: userDialogs.map((d) => d.chatId),
//   })

//   // // 8. Encode everything to protocol buffer types
//   const encodedDialogs = userDialogs.map((dialog) => {
//     const unreadCount = unreadCounts.find((uc) => uc.chatId === dialog.chatId)?.unreadCount ?? 0
//     return Encoders.dialog(dialog, { unreadCount })
//   })

//   const encodedChats = chatsList.map((chat) => Encoders.chat(chat, { encodingForUserId: currentUserId }))
//   const encodedSpaces = spacesList.map((space) => Encoders.space(space, { encodingForUserId: currentUserId }))
//   const encodedUsers = usersList.map((user) => Encoders.user({ user }))

//   return {
//     chats: encodedChats,
//     dialogs: encodedDialogs,
//     spaces: encodedSpaces,
//     users: encodedUsers,
//     messages: messagesList,
//   }
// }
