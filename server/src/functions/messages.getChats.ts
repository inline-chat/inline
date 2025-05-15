import type { Chat, Dialog, InputPeer, Message, MessageAttachment, Space, User } from "@in/protocol/core"
import { ModelError } from "@in/server/db/models/_errors"
import { MessageModel, type DbFullMessage } from "@in/server/db/models/messages"
import type { FunctionContext } from "@in/server/functions/_types"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { Log } from "@in/server/utils/log"
import { db } from "@in/server/db"
import { and, eq, inArray, isNull, or } from "drizzle-orm"
import {
  chats,
  dialogs,
  files,
  messages,
  spaces,
  users,
  members,
  chatParticipants,
  type DbSpace,
  type DbChat,
  type DbDialog,
  type DbUser,
} from "@in/server/db/schema"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { encodePeerFromChat } from "@in/server/realtime/encoders/encodePeer"

type Input = {}

type Output = {
  chats: Chat[]
  dialogs: Dialog[]
  spaces: Space[]
  users: User[]
  messages: Message[]
}

const log = new Log("functions.getChats")

export const getChats = async (input: Input, context: FunctionContext): Promise<Output> => {
  const currentUserId = context.currentUserId

  // Buckets for results
  let dialogsList: DbDialog[] = []
  let usersList: DbUser[] = []
  let chatsList: DbChat[] = []
  let messagesList: Message[] = []
  let spacesList: DbSpace[] = []

  // // 1. Get all spaces the user is a part of
  const userSpaces = await db.query.spaces.findMany({
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
  const chats = await db.query.chats.findMany({
    where: {
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
            },
          },
        },

        // Private threads
        {
          type: "thread",
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
      ],
    },

    with: {
      // dialogs for this user
      dialogs: {
        where: {
          userId: currentUserId,
        },

        with: {
          peerUser: true,
        },
      },

      lastMsg: {
        with: {
          from: true,
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
            },
          },
          reactions: true,
          messageAttachments: {
            with: {
              externalTask: true,
              linkEmbed: {
                with: {
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
            },
          },
        },
      },
    },
  })

  console.log("chats", chats)

  // Create dialogs for all chats that don't have a dialog
  const chatsThatNeedDialogs = chats.filter((c) => c.dialogs.length === 0)
  if (chatsThatNeedDialogs.length > 0) {
    let createdDialogs = await db
      .insert(dialogs)
      .values(
        chatsThatNeedDialogs.map((c) => ({
          chatId: c.id,
          userId: currentUserId,
          // type-specific fields
          peerUserId: c.type === "private" ? (c.minUserId === currentUserId ? c.maxUserId : c.minUserId) : null,
          spaceId: c.type === "thread" ? c.spaceId : null,
        })),
      )
      .returning()

    // Add created dialogs to the list
    dialogsList = [...dialogsList, ...createdDialogs]
  }

  // Add chats to results
  chats.forEach((chat) => {
    // chat
    chatsList.push(chat)

    // last message
    if (chat.lastMsg) {
      const processedMsg = MessageModel.processMessage(chat.lastMsg)
      const encodedMsg = Encoders.fullMessage({
        message: processedMsg,
        encodingForUserId: currentUserId,
        encodingForPeer: { inputPeer: encodePeerFromChat(chat, { currentUserId }) },
      })
      if (processedMsg) {
        messagesList.push(encodedMsg)
      }
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

  // // 7. Get unread counts for all dialogs
  const unreadCounts = await DialogsModel.getBatchUnreadCounts({
    userId: currentUserId,
    chatIds: dialogsList.map((d) => d.chatId),
  })

  // // 8. Encode everything to protocol buffer types
  const encodedDialogs = dialogsList.map((dialog) => {
    const unreadCount = unreadCounts.find((uc) => uc.chatId === dialog.chatId)?.unreadCount ?? 0
    return Encoders.dialog(dialog, { unreadCount })
  })

  const encodedChats = chatsList.map((chat) => Encoders.chat(chat, { encodingForUserId: currentUserId }))
  const encodedSpaces = spacesList.map((space) => Encoders.space(space, { encodingForUserId: currentUserId }))
  const encodedUsers = usersList.map((user) => Encoders.user({ user }))

  return {
    chats: encodedChats,
    dialogs: encodedDialogs,
    spaces: encodedSpaces,
    users: encodedUsers,
    messages: messagesList,
  }
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
