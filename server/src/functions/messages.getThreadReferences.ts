import {
  GetThreadReferencesInput,
  GetThreadReferencesResult,
  GetThreadSubthreadsInput,
  GetThreadSubthreadsResult,
  ThreadReferenceItem,
  ThreadReferenceKind,
} from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { DialogsModel } from "@in/server/db/models/dialogs"
import { dialogs, type DbChat, type DbDialog, type DbThreadGraphLink } from "@in/server/db/schema"
import type { FunctionContext } from "@in/server/functions/_types"
import { getReferences, getSubthreads } from "@in/server/modules/threadGraph/queries"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDate } from "@in/server/realtime/encoders/helpers"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { and, eq, inArray } from "drizzle-orm"

type ThreadRelationshipInput = GetThreadReferencesInput | GetThreadSubthreadsInput
type ThreadRelationshipResult = GetThreadReferencesResult | GetThreadSubthreadsResult

export async function getThreadReferences(
  input: GetThreadReferencesInput,
  context: FunctionContext,
): Promise<GetThreadReferencesResult> {
  return getThreadRelationshipList(input, context, "references")
}

export async function getThreadSubthreads(
  input: GetThreadSubthreadsInput,
  context: FunctionContext,
): Promise<GetThreadSubthreadsResult> {
  return getThreadRelationshipList(input, context, "subthreads")
}

async function getThreadRelationshipList(
  input: ThreadRelationshipInput,
  context: FunctionContext,
  list: "references" | "subthreads",
): Promise<ThreadRelationshipResult> {
  const chatId = normalizeId(input.chatId)
  const offsetId = normalizeOptionalOffsetId(input.offsetId)
  const rows =
    list === "references"
      ? await getReferences({
          chatId,
          currentUserId: context.currentUserId,
          limit: input.limit,
          beforeId: offsetId,
        })
      : await getSubthreads({
          chatId,
          currentUserId: context.currentUserId,
          limit: input.limit,
          beforeId: offsetId,
        })

  const relatedChats = uniqueChats(rows.relatedChats)
  const relatedChatIds = relatedChats.map((chat) => chat.id)
  const relatedDialogs = await getCurrentUserDialogs({
    chatIds: relatedChatIds,
    userId: context.currentUserId,
  })
  const unreadCounts = await DialogsModel.getBatchUnreadCounts({
    userId: context.currentUserId,
    chatIds: relatedDialogs.map((dialog) => dialog.chatId).filter((chatId): chatId is number => chatId !== null),
  })
  const unreadCountByChatId = new Map(unreadCounts.map((row) => [row.chatId, row.unreadCount]))
  const encodedChats = await Encoders.chatsForUser(relatedChats, { encodingForUserId: context.currentUserId })

  return {
    items: rows.links.map(encodeItem),
    chats: encodedChats,
    dialogs: relatedDialogs.map((dialog) =>
      Encoders.dialog(dialog, {
        unreadCount: dialog.chatId === null ? 0 : unreadCountByChatId.get(dialog.chatId) ?? 0,
      }),
    ),
  }
}

function encodeItem(link: DbThreadGraphLink): ThreadReferenceItem {
  return {
    id: link.id,
    kind: encodeKind(link.kind),
    fromChatId: BigInt(link.fromChatId),
    fromMessageId: link.fromMessageId !== null ? BigInt(link.fromMessageId) : undefined,
    toChatId: BigInt(link.toChatId),
    date: encodeDate(link.date),
  }
}

function encodeKind(kind: DbThreadGraphLink["kind"]): ThreadReferenceKind {
  switch (kind) {
    case "thread_link":
      return ThreadReferenceKind.THREAD_LINK
    case "reply_thread":
      return ThreadReferenceKind.REPLY_THREAD
  }
}

async function getCurrentUserDialogs(input: { chatIds: number[]; userId: number }): Promise<DbDialog[]> {
  const chatIds = Array.from(new Set(input.chatIds))
  if (chatIds.length === 0) {
    return []
  }

  return db
    .select()
    .from(dialogs)
    .where(and(eq(dialogs.userId, input.userId), inArray(dialogs.chatId, chatIds)))
}

function uniqueChats(chats: DbChat[]): DbChat[] {
  const byId = new Map<number, DbChat>()
  for (const chat of chats) {
    byId.set(chat.id, chat)
  }
  return Array.from(byId.values())
}

function normalizeId(id: bigint): number {
  if (id <= 0n || id > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw RealtimeRpcError.ChatIdInvalid()
  }
  return Number(id)
}

function normalizeOptionalOffsetId(id: bigint | undefined): bigint | undefined {
  if (id === undefined) {
    return undefined
  }
  if (id <= 0n) {
    throw RealtimeRpcError.BadRequest()
  }
  return id
}
