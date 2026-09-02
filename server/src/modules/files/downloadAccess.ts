import type { FileMessageLocation } from "@inline-chat/protocol/core"
import { eq, sql } from "drizzle-orm"
import { db } from "@in/server/db"
import { getFileByUniqueId } from "@in/server/db/models/files"
import { chats, spaces } from "@in/server/db/schema"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { INLINE_TRANSFER_MAX_LOCATOR_ID } from "@inline-chat/protocol/transfers"

// Resolve one message, never reverse-scan the message history for a file ID.
export async function resolveDownloadFile(
  fileUniqueId: string,
  userId: number,
  message?: FileMessageLocation,
) {
  if (message && (message.chatId <= 0n || message.messageId <= 0n ||
      message.chatId > INLINE_TRANSFER_MAX_LOCATOR_ID || message.messageId > INLINE_TRANSFER_MAX_LOCATOR_ID)) {
    return undefined
  }
  const file = await getFileByUniqueId(fileUniqueId)
  if (!file) return undefined
  if (file.userId === userId) return file
  if (!message) return undefined

  const [accessScope] = await db.select({ chat: chats, spaceDeleted: spaces.deleted })
    .from(chats)
    .leftJoin(spaces, eq(chats.spaceId, spaces.id))
    .where(eq(chats.id, Number(message.chatId)))
    .limit(1)
  const chat = accessScope?.chat
  if (!chat || (chat.spaceId !== null && accessScope.spaceDeleted !== null)) return undefined
  try {
    await AccessGuards.ensureChatAccess(chat, userId)
  } catch (error) {
    // Preserve operational errors, but make missing/inaccessible files alike.
    if (error instanceof RealtimeRpcError) return undefined
    throw error
  }

  const references = await db.execute(sql`
    select 1 from messages message
    where message.chat_id = ${Number(message.chatId)}
      and message.message_id = ${Number(message.messageId)}
      and (
        message.file_id = ${file.id}
        or exists (select 1 from photo_sizes p where p.photo_id = message.photo_id and p.file_id = ${file.id})
        or exists (
          select 1 from documents d where d.id = message.document_id and (
            d.file_id = ${file.id}
            or exists (select 1 from photo_sizes p where p.photo_id = d.photo_id and p.file_id = ${file.id})
          )
        )
        or exists (
          select 1 from videos v where v.id = message.video_id and (
            v.file_id = ${file.id}
            or exists (select 1 from photo_sizes p where p.photo_id = v.photo_id and p.file_id = ${file.id})
          )
        )
        or exists (select 1 from voices v where v.id = message.voice_id and v.file_id = ${file.id})
        or exists (
          select 1 from message_attachments attachment
          join url_preview preview on preview.id = attachment.url_preview_id
          where attachment.message_id = message.global_id and (
            exists (select 1 from photo_sizes p where p.photo_id in (preview.photo_id, preview.author_photo_id) and p.file_id = ${file.id})
            or exists (
              select 1 from videos v where v.id = preview.video_id and (
                v.file_id = ${file.id}
                or exists (select 1 from photo_sizes p where p.photo_id = v.photo_id and p.file_id = ${file.id})
              )
            )
            or exists (
              select 1 from documents d where d.id = preview.document_id and (
                d.file_id = ${file.id}
                or exists (select 1 from photo_sizes p where p.photo_id = d.photo_id and p.file_id = ${file.id})
              )
            )
          )
        )
        or exists (
          select 1 from block_content_image_jobs image
          join block_contents content on content.id = image.content_id
          join photo_sizes p on p.photo_id = image.photo_id
          where image.content_id = message.block_content_id and p.file_id = ${file.id}
            and image.state = 'ready' and image.expected_revision = content.revision
        )
      )
    limit 1
  `)
  return references.length > 0 ? file : undefined
}
