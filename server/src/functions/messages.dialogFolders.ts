import {
  DeleteDialogFolderDisposition,
  type CreateDialogFolderResult,
  type DeleteDialogFolderResult,
  type InputPeer,
  type UpdateDialogFolderResult,
} from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { ChatModel } from "@in/server/db/models/chats"
import { dialogFolders, dialogs, users, type DbDialog } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import {
  encodeFolderDialogs,
  enqueueDialogFolderUpdate,
  folderChildren,
  ownedDialogFolder,
  pushDialogFolderUpdate,
  rootDialogFolderPositions,
} from "@in/server/modules/dialogFolders"
import { FractionalIndex } from "@in/server/modules/fractionalIndex"
import { maybeScheduleDialogFolderTitleGeneration } from "@in/server/modules/dialogFolderTitles"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { and, eq, inArray } from "drizzle-orm"

const MAX_FOLDER_TITLE_LENGTH = 80
const MAX_FOLDER_DIALOGS = 100
const MAX_FOLDER_EMOJI_INPUT_LENGTH = 128

type TitleUpdate =
  | { oneofKind: "title"; title: string }
  | { oneofKind: "clearTitle"; clearTitle: boolean }
  | { oneofKind: undefined }

type EmojiUpdate =
  | { oneofKind: "emoji"; emoji: string }
  | { oneofKind: "clearEmoji"; clearEmoji: boolean }
  | { oneofKind: undefined }

type PinnedOrderUpdate =
  | { oneofKind: "pinnedOrder"; pinnedOrder: string }
  | { oneofKind: "clearPinnedOrder"; clearPinnedOrder: boolean }
  | { oneofKind: undefined }

type ResolvedChat = Awaited<ReturnType<typeof ChatModel.getChatFromInputPeer>>

export async function createDialogFolder(
  input: { title?: string; peers: InputPeer[]; order?: string; pinnedOrder?: string },
  context: FunctionContext,
): Promise<CreateDialogFolderResult> {
  if (
    input.peers.length > MAX_FOLDER_DIALOGS ||
    (input.order != null && !FractionalIndex.isValid(input.order)) ||
    (input.pinnedOrder != null && !FractionalIndex.isValid(input.pinnedOrder))
  ) {
    throw RealtimeRpcError.BadRequest()
  }
  const title = normalizeOptionalTitle(input.title)
  const chats = await resolveUniqueChats(input.peers, context)

  const result = await db.transaction(async (tx) => {
    await lockUser(tx, context.currentUserId)
    const chatIds = chats.map((chat) => chat.id)
    const existingDialogs = chatIds.length === 0
      ? []
      : await tx
          .select()
          .from(dialogs)
          .where(and(eq(dialogs.userId, context.currentUserId), inArray(dialogs.chatId, chatIds)))

    if (existingDialogs.length !== chatIds.length) {
      throw RealtimeRpcError.BadRequest()
    }

    const positions = await rootDialogFolderPositions(tx, {
      userId: context.currentUserId,
      excludingChatIds: chatIds,
    })
    const folderOrder = input.order ?? FractionalIndex.before(positions[0])
    const childOrders = allocateOrdersAfter(folderOrder, nextPosition(positions, folderOrder), chats.length)

    const [folder] = await tx
      .insert(dialogFolders)
      .values({
        userId: context.currentUserId,
        title,
        order: folderOrder,
        pinnedOrder: input.pinnedOrder ?? null,
      })
      .returning()
    if (!folder) throw RealtimeRpcError.InternalError()

    const dialogsByChatId = new Map(existingDialogs.map((dialog) => [dialog.chatId, dialog]))
    const changedDialogs: DbDialog[] = []
    for (const [index, chat] of chats.entries()) {
      const current = dialogsByChatId.get(chat.id)
      if (!current) throw RealtimeRpcError.InternalError()
      const [changed] = await tx
        .update(dialogs)
        .set({
          folderId: folder.id,
          order: childOrders[index],
          open: true,
          archived: false,
          pinned: false,
          chatListHidden: null,
        })
        .where(and(eq(dialogs.id, current.id), eq(dialogs.userId, context.currentUserId)))
        .returning()
      if (!changed) throw RealtimeRpcError.InternalError()
      changedDialogs.push(changed)
    }

    const encodedFolder = Encoders.dialogFolder(folder)
    const encodedDialogs = await encodeFolderDialogs(tx, changedDialogs)
    const persisted = await enqueueDialogFolderUpdate({
      tx,
      userId: context.currentUserId,
      folderChange: { oneofKind: "folder", folder: encodedFolder },
      dialogs: encodedDialogs,
    })
    const peerNames = await peerDisplayNames(tx, existingDialogs)
    return { folder: encodedFolder, dialogs: encodedDialogs, update: persisted.update, peerNames }
  })

  pushDialogFolderUpdate(context.currentUserId, result.update, context.currentSessionId)
  if (title === null) {
    maybeScheduleDialogFolderTitleGeneration({
      folderId: Number(result.folder.id),
      userId: context.currentUserId,
      peerNames: result.peerNames,
    })
  }
  return { folder: result.folder, dialogs: result.dialogs }
}

export async function updateDialogFolder(
  input: {
    folderId: number
    titleUpdate: TitleUpdate
    emojiUpdate: EmojiUpdate
    pinnedOrderUpdate?: PinnedOrderUpdate
    order?: string
  },
  context: FunctionContext,
): Promise<UpdateDialogFolderResult> {
  const pinnedOrderUpdate = input.pinnedOrderUpdate ?? { oneofKind: undefined }
  if (
    input.folderId <= 0 ||
    (input.order != null && !FractionalIndex.isValid(input.order)) ||
    (pinnedOrderUpdate.oneofKind === "pinnedOrder"
      && !FractionalIndex.isValid(pinnedOrderUpdate.pinnedOrder)) ||
    (input.order == null
      && input.titleUpdate.oneofKind === undefined
      && input.emojiUpdate.oneofKind === undefined
      && pinnedOrderUpdate.oneofKind === undefined)
  ) {
    throw RealtimeRpcError.BadRequest()
  }

  const title = titleValue(input.titleUpdate)
  const emoji = emojiValue(input.emojiUpdate)
  const pinnedOrder = pinnedOrderValue(pinnedOrderUpdate)
  const result = await db.transaction(async (tx) => {
    await lockUser(tx, context.currentUserId)
    const folder = await ownedDialogFolder(tx, context.currentUserId, input.folderId)
    if (!folder) throw RealtimeRpcError.BadRequest()

    const children = await folderChildren(tx, context.currentUserId, folder.id)
    let changedDialogs = children
    if (input.order != null && input.order !== folder.order) {
      const positions = await rootDialogFolderPositions(tx, {
        userId: context.currentUserId,
        excludingFolderId: folder.id,
        excludingChatIds: children.map((dialog) => dialog.chatId),
      })
      const childOrders = allocateOrdersAfter(input.order, nextPosition(positions, input.order), children.length)
      changedDialogs = []
      for (const [index, child] of children.entries()) {
        const [changed] = await tx
          .update(dialogs)
          .set({ order: childOrders[index] })
          .where(and(eq(dialogs.id, child.id), eq(dialogs.userId, context.currentUserId)))
          .returning()
        if (!changed) throw RealtimeRpcError.InternalError()
        changedDialogs.push(changed)
      }
    }

    const updateSet: Partial<typeof dialogFolders.$inferInsert> = {}
    if (input.order != null) updateSet.order = input.order
    if (title !== undefined) updateSet.title = title
    if (emoji !== undefined) updateSet.emoji = emoji
    if (pinnedOrder !== undefined) updateSet.pinnedOrder = pinnedOrder
    const [updatedFolder] = await tx
      .update(dialogFolders)
      .set(updateSet)
      .where(and(eq(dialogFolders.id, folder.id), eq(dialogFolders.userId, context.currentUserId)))
      .returning()
    if (!updatedFolder) throw RealtimeRpcError.InternalError()

    const encodedFolder = Encoders.dialogFolder(updatedFolder)
    const encodedDialogs = input.order == null ? [] : await encodeFolderDialogs(tx, changedDialogs)
    const persisted = await enqueueDialogFolderUpdate({
      tx,
      userId: context.currentUserId,
      folderChange: { oneofKind: "folder", folder: encodedFolder },
      dialogs: encodedDialogs,
    })
    return { folder: encodedFolder, dialogs: encodedDialogs, update: persisted.update }
  })

  pushDialogFolderUpdate(context.currentUserId, result.update, context.currentSessionId)
  return { folder: result.folder, dialogs: result.dialogs }
}

export async function deleteDialogFolder(
  input: { folderId: number; disposition: DeleteDialogFolderDisposition },
  context: FunctionContext,
): Promise<DeleteDialogFolderResult> {
  if (
    input.folderId <= 0 ||
    ![DeleteDialogFolderDisposition.CLOSE_DIALOGS, DeleteDialogFolderDisposition.KEEP_DIALOGS].includes(
      input.disposition,
    )
  ) {
    throw RealtimeRpcError.BadRequest()
  }

  const result = await db.transaction(async (tx) => {
    await lockUser(tx, context.currentUserId)
    const folder = await ownedDialogFolder(tx, context.currentUserId, input.folderId)
    if (!folder) throw RealtimeRpcError.BadRequest()
    const children = await folderChildren(tx, context.currentUserId, folder.id)

    const changedDialogs: DbDialog[] = []
    for (const child of children) {
      const close = input.disposition === DeleteDialogFolderDisposition.CLOSE_DIALOGS
      const [changed] = await tx
        .update(dialogs)
        .set({
          folderId: null,
          ...(close ? { open: false, openedDate: null, order: null } : {}),
        })
        .where(and(eq(dialogs.id, child.id), eq(dialogs.userId, context.currentUserId)))
        .returning()
      if (!changed) throw RealtimeRpcError.InternalError()
      changedDialogs.push(changed)
    }

    await tx
      .delete(dialogFolders)
      .where(and(eq(dialogFolders.id, folder.id), eq(dialogFolders.userId, context.currentUserId)))

    const encodedDialogs = await encodeFolderDialogs(tx, changedDialogs)
    const deletedFolderId = BigInt(folder.id)
    const persisted = await enqueueDialogFolderUpdate({
      tx,
      userId: context.currentUserId,
      folderChange: { oneofKind: "deletedFolderId", deletedFolderId },
      dialogs: encodedDialogs,
    })
    return { folderId: deletedFolderId, dialogs: encodedDialogs, update: persisted.update }
  })

  pushDialogFolderUpdate(context.currentUserId, result.update, context.currentSessionId)
  return { folderId: result.folderId, dialogs: result.dialogs }
}

async function resolveUniqueChats(peers: InputPeer[], context: FunctionContext): Promise<ResolvedChat[]> {
  const result: ResolvedChat[] = []
  const seen = new Set<number>()
  for (const peer of peers) {
    const chat = await ChatModel.getChatFromInputPeer(peer, context)
    await AccessGuards.ensureChatAccess(chat, context.currentUserId)
    if (!seen.has(chat.id)) {
      seen.add(chat.id)
      result.push(chat)
    }
  }
  return result
}

function emojiValue(update: EmojiUpdate): string | null | undefined {
  switch (update.oneofKind) {
    case "emoji":
      return normalizeEmoji(update.emoji)
    case "clearEmoji":
      if (!update.clearEmoji) throw RealtimeRpcError.BadRequest()
      return null
    case undefined:
      return undefined
  }
}

function pinnedOrderValue(update: PinnedOrderUpdate): string | null | undefined {
  switch (update.oneofKind) {
    case "pinnedOrder":
      return update.pinnedOrder
    case "clearPinnedOrder":
      if (!update.clearPinnedOrder) throw RealtimeRpcError.BadRequest()
      return null
    case undefined:
      return undefined
  }
}

function normalizeEmoji(value: string): string {
  if (value.length > MAX_FOLDER_EMOJI_INPUT_LENGTH) throw RealtimeRpcError.BadRequest()
  const trimmed = value.trim()
  const graphemes = Array.from(new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(trimmed))
  if (graphemes.length !== 1) throw RealtimeRpcError.BadRequest()
  const emoji = graphemes[0]?.segment
  const containsEmoji = emoji != null
    && (
      /[\p{Emoji_Presentation}\p{Extended_Pictographic}\u{1F1E6}-\u{1F1FF}]/u.test(emoji)
      || emoji.includes("\u{20E3}")
    )
  if (!emoji || !containsEmoji || Array.from(emoji).length > 16) {
    throw RealtimeRpcError.BadRequest()
  }
  return emoji
}

function normalizeOptionalTitle(title: string | undefined): string | null {
  if (title === undefined) return null
  return normalizeTitle(title)
}

function normalizeTitle(title: string): string {
  const normalized = title.trim().replace(/\s+/g, " ")
  if (normalized.length === 0 || Array.from(normalized).length > MAX_FOLDER_TITLE_LENGTH) {
    throw RealtimeRpcError.BadRequest()
  }
  return normalized
}

function titleValue(update: TitleUpdate): string | null | undefined {
  switch (update.oneofKind) {
    case "title":
      return normalizeTitle(update.title)
    case "clearTitle":
      if (!update.clearTitle) throw RealtimeRpcError.BadRequest()
      return null
    case undefined:
      return undefined
  }
}

function allocateOrdersAfter(anchor: string, right: string | undefined, count: number): string[] {
  const result: string[] = []
  let previous = anchor
  for (let index = 0; index < count; index += 1) {
    previous = FractionalIndex.between(previous, right)
    result.push(previous)
  }
  return result
}

function nextPosition(positions: string[], order: string): string | undefined {
  return positions.find((position) => position > order)
}

async function lockUser(tx: Transaction, userId: number): Promise<void> {
  await tx.select({ id: users.id }).from(users).where(eq(users.id, userId)).for("update").limit(1)
}

async function peerDisplayNames(tx: Transaction, rows: DbDialog[]): Promise<string[]> {
  const peerUserIds = rows.flatMap((dialog) => (dialog.peerUserId == null ? [] : [dialog.peerUserId]))
  if (peerUserIds.length === 0) return []
  const peers = await tx
    .select({ firstName: users.firstName, lastName: users.lastName, username: users.username })
    .from(users)
    .where(inArray(users.id, peerUserIds))
  return peers.flatMap((peer) => {
    const name = [peer.firstName, peer.lastName].filter(Boolean).join(" ").trim() || peer.username?.trim()
    return name ? [name] : []
  })
}
