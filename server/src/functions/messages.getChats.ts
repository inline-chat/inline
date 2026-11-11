import { resolveTimeZoneVisibility } from "@in/server/modules/privacy/timeZoneVisibility"
import { resolveFocusForViewer } from "@in/server/modules/privacy/focusStatus"
import { syncChatAccess } from "@in/server/modules/authorization/chatAccessSync"
import type { Chat, ChatListOffset, Dialog, DialogFolder, GetChatsInput, Message, Space, User } from "@inline-chat/protocol/core"
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
  type DbChat,
  type DbDialog,
  type DbNewDialog,
  type DbUser,
  type DbFile,
} from "@in/server/db/schema"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { getActivityCountsForChats } from "@in/server/modules/activityItems"
import { encodePeerFromChat } from "@in/server/realtime/encoders/encodePeer"
import { dialogOpenDefaultsForChat } from "@in/server/modules/dialogOpen"
import { getDialogFolders } from "@in/server/modules/dialogFolders"
import { getEffectiveChatAccessUserIds } from "@in/server/modules/authorization/chatAccessProjection"
import { getMessageThreadProjectionsByParent } from "@in/server/modules/subthreads"
import { catalogDiagnostics, type CatalogWork } from "@in/server/modules/message/catalogDiagnostics"
import {
  completeCatalogCte,
  discoverChatListPage,
  nextOffsetFor,
  parseChatListRequest,
  type ChatListRequest,
} from "@in/server/modules/chatList/pagedChatList"
import { connectionManager } from "@in/server/ws/connections"

// Callers may omit the paging fields; they take their protobuf defaults.
type Input = Partial<GetChatsInput>

type Output = {
  chats: Chat[]
  dialogs: Dialog[]
  spaces: Space[]
  users: User[]
  messages: Message[]
  folders: DialogFolder[]
  nextOffset?: ChatListOffset
}

const log = new Log("functions.getChats")

// Discover candidates through scoped roots or explicit target grants, never by
// scanning every home subthread. The access projection below remains the sole
// authority for what may be returned, including retained grants after revocation.
async function getCompleteCatalogChatIds(currentUserId: number, query: Pick<typeof db, "execute">): Promise<number[]> {
  const rows = await query.execute<{ chatId: number }>(sql`
    with recursive ${completeCatalogCte(currentUserId)}
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
      newChats = await db.transaction(async (tx) => {
        const inserted = await tx
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
        await syncChatAccess(tx, { kind: "chats", chatIds: inserted.map((chat) => chat.id) })
        return inserted
      })
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
async function prepareCatalogDialogs(input: Input, currentUserId: number, work: CatalogWork): Promise<void> {
  const candidates = await db.query.chats.findMany({
    columns: { id: true, type: true, minUserId: true, maxUserId: true, spaceId: true },
    where: {
      AND: [
        input.includeSubthreads === true
          ? {
              // Only roots can need preparation: the root seeds of the complete
              // catalog that can grant access. Space membership alone reaches
              // public threads only; a private thread needs a participant or
              // group grant, so inaccessible private threads are not re-checked
              // against the projection on every call.
              RAW: (chat) => sql`(
                (${chat.type} = 'private' and (${chat.minUserId} = ${currentUserId} or ${chat.maxUserId} = ${currentUserId}))
                or (${chat.type} = 'thread' and (
                  (${chat.publicThread} is true and exists (
                    select 1 from members m
                    where m.space_id = ${chat.spaceId}
                      and m.user_id = ${currentUserId}
                      and m.can_access_public_chats is distinct from false
                  ))
                  or exists (select 1 from chat_participants cp where cp.chat_id = ${chat.id} and cp.user_id = ${currentUserId})
                  or exists (
                    select 1 from chat_participant_groups cpg
                    join user_group_members ugm on ugm.group_id = cpg.group_id
                    where cpg.chat_id = ${chat.id} and ugm.user_id = ${currentUserId}
                  )
                ))
              )
              `,
            }
          : await getCatalogWhere(currentUserId, false, db),
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
  work.preparationCandidates = candidates.length
  if (candidates.length === 0) return
  const access = await getEffectiveChatAccessUserIds(
    db,
    candidates.map((chat) => chat.id),
    {
      userIds: [currentUserId],
      source: "chats.list",
      committed: true,
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
  if (input.limit !== undefined) return getChatsPage(parseChatListRequest(input), context)

  const connection = context.currentConnectionId
    ? connectionManager.getConnection(context.currentConnectionId)
    : connectionManager.getConnectionBySession(context.currentUserId, context.currentSessionId)
  return catalogDiagnostics.observe({
    clientType: connection?.clientType,
    version: connection?.version,
    isBot: context.isBot ?? connection?.isBot,
    includeSubthreads: input.includeSubthreads === true,
  }, async (work) => {
    const prepareStarted = performance.now()
    try { await prepareCatalogDialogs(input, context.currentUserId, work) }
    finally { work.prepareMs = performance.now() - prepareStarted }
    const snapshotStarted = performance.now()
    try { return await readCatalog(input, context, work) }
    finally { work.snapshotMs = performance.now() - snapshotStarted }
  })
}

/**
 * Paged list. Read-only: one discovery statement picks the page (scope, filter,
 * cursor and access), then only that page is hydrated.
 */
async function getChatsPage(request: ChatListRequest, context: FunctionContext): Promise<Output> {
  const currentUserId = context.currentUserId
  return withHistoryReadSnapshot(async (tx) => {
    const rows = await discoverChatListPage(tx, currentUserId, request)
    const page = rows.slice(0, request.limit)
    const nextOffset = rows.length > request.limit ? nextOffsetFor(request, page[page.length - 1]!) : undefined
    const folders = request.offset === undefined ? (await getDialogFolders(currentUserId, tx)).map(Encoders.dialogFolder) : []
    if (page.length === 0) return { chats: [], dialogs: [], spaces: [], users: [], messages: [], folders, nextOffset }

    const pageIds = page.map((row) => row.chatId)
    const found = await findHydratableChats(tx, currentUserId, { id: { in: pageIds } })
    const byId = new Map(found.map((chat) => [chat.id, chat]))
    const ordered = pageIds.flatMap((chatId) => {
      const chat = byId.get(chatId)
      return chat ? [chat] : []
    })
    const hydrated = await hydrateChats(tx, currentUserId, ordered)

    const spaceIds = [...new Set(ordered.flatMap((chat) => (chat.spaceId == null ? [] : [chat.spaceId])))]
    const spaceRows = spaceIds.length === 0
      ? []
      : await tx.select().from(spaces).where(and(inArray(spaces.id, spaceIds), isNull(spaces.deleted)))
    return {
      ...hydrated,
      spaces: spaceRows.map((space) => Encoders.space(space, { encodingForUserId: currentUserId })),
      folders,
      nextOffset,
    }
  })
}

/** Chats with what hydration reads: the viewer's dialog and peer, and the last message with media. */
function findHydratableChats(tx: Transaction, currentUserId: number, where: CatalogWhere) {
  return tx.query.chats.findMany({
    where,
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
}

type HydratableChat = Awaited<ReturnType<typeof findHydratableChats>>[number]

async function readCatalog(input: Input, context: FunctionContext, work: CatalogWork): Promise<Output> {
  const currentUserId = context.currentUserId
  return withHistoryReadSnapshot(async (tx) => {
    const foldersList = await getDialogFolders(currentUserId, tx)

    // 1. Get all spaces the user is a part of
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

    // Discovery is not authorization. Check every candidate against this exact
    // catalog snapshot before reading its metadata, previews or senders.
    const candidates = await tx.query.chats.findMany({
      columns: { id: true },
      where: await getCatalogWhere(currentUserId, input.includeSubthreads === true, tx),
    })
    work.candidateChats = candidates.length
    const chatAccess = await getEffectiveChatAccessUserIds(
      tx,
      candidates.map((chat) => chat.id),
      {
        userIds: [currentUserId],
        source: "chats.list",
        committed: true,
      },
    )
    const allowedIds = candidates.flatMap((chat) => (chatAccess.get(chat.id)?.has(currentUserId) === true ? [chat.id] : []))
    const chats = allowedIds.length === 0 ? [] : await findHydratableChats(tx, currentUserId, { id: { in: allowedIds } })
    const hydrated = await hydrateChats(tx, currentUserId, chats)

    return {
      ...hydrated,
      spaces: userSpaces.map((space) => Encoders.space(space, { encodingForUserId: currentUserId })),
      folders: foldersList.map(Encoders.dialogFolder),
    }
  })
}

/**
 * Encodes authorized chats with their dialogs, last messages and the users
 * they reference. Shared by the unpaged snapshot and pages so objects match.
 */
async function hydrateChats(
  tx: Transaction,
  currentUserId: number,
  chats: HydratableChat[],
): Promise<Pick<Output, "chats" | "dialogs" | "users" | "messages">> {
  const dialogsList: DbDialog[] = []
  const usersList: (DbUser & { photoFile?: DbFile | null })[] = []
  const chatsList: DbChat[] = []

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
  // DMs listed without a stored dialog (paged ACCESSIBLE scope) still reference their peer.
  const peerUserIdsWithoutDialog = new Set<number>()
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

    const dialog = chat.dialogs[0]
    if (dialog) {
      dialogsList.push(dialog)
      // peer user
      if (dialog.peerUser) {
        usersList.push(dialog.peerUser)
      }
    } else if (chat.type === "private") {
      const peerUserId = chat.minUserId === currentUserId ? chat.maxUserId : chat.minUserId
      if (peerUserId != null) peerUserIdsWithoutDialog.add(peerUserId)
    }
  })

  if (missingLastMsgKeys.length > 0) {
    const chatsById = new Map(chatsList.map((chat) => [chat.id, chat]))
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
      const chat = chatsById.get(chatId)
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

  if (peerUserIdsWithoutDialog.size > 0) {
    usersList.push(...await tx.query.users.findMany({
      where: { id: { in: [...peerUserIdsWithoutDialog] } },
      with: { photoFile: true },
    }))
  }

  // Get unread counts for all dialogs
  const dialogChatIds = dialogsList.map((d) => d.chatId)
  const unreadCounts = new Map(
    (await DialogsModel.getBatchUnreadCounts({ userId: currentUserId, chatIds: dialogChatIds, tx }))
      .map((row) => [row.chatId, row.unreadCount]),
  )
  const activityCounts = await getActivityCountsForChats({
    userId: currentUserId,
    chatIds: dialogChatIds,
    tx,
  })

  // Encode everything to protocol buffer types
  const encodedDialogs = dialogsList.map((dialog) =>
    Encoders.dialog(dialog, {
      unreadCount: unreadCounts.get(dialog.chatId) ?? 0,
      unreadActivity: activityCounts.get(dialog.chatId),
    }),
  )

  const usersById = new Map<number, DbUser & { photoFile?: DbFile | null }>()
  for (const user of usersList) {
    const existing = usersById.get(user.id)
    if (!existing || (!existing.photoFile && user.photoFile)) {
      usersById.set(user.id, user)
    }
  }

  const encodedChats = await Encoders.chatsForUser(chatsList, { encodingForUserId: currentUserId, tx })
  const privateChats = chatsList.filter((chat) => chat.type === "private")
  const dmPeerUserIds = new Set(privateChats.flatMap((chat) => {
    const peerUserId = chat.minUserId === currentUserId ? chat.maxUserId : chat.minUserId
    return peerUserId == null ? [] : [peerUserId]
  }))
  const dmPeers = Array.from(usersById.values()).filter((user) => dmPeerUserIds.has(user.id))
  const timeZoneVisible = await resolveTimeZoneVisibility(currentUserId, dmPeers)
  const focusByUserId = await resolveFocusForViewer(currentUserId, dmPeers.filter((user) => user.bot !== true))
  const encodedUsers = Array.from(usersById.values()).map((user) =>
    Encoders.user({
      user,
      photoFile: user.photoFile ?? undefined,
      min: true,
      includeTimeZone: dmPeerUserIds.has(user.id),
      timeZoneVisible: timeZoneVisible.has(user.id),
      focus: focusByUserId.get(user.id),
      includeBotStatus: dmPeerUserIds.has(user.id),
      viewerUserId: currentUserId,
    }),
  )

  return {
    chats: encodedChats,
    dialogs: encodedDialogs,
    users: encodedUsers,
    messages: Array.from(messagesByKey.values()),
  }
}
