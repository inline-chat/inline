import type { RichMessage } from "@inline-chat/protocol/core"
import { messageRichMedia, type DbNewMessageRichMedia } from "@in/server/db/schema/messageRichMedia"
import type { Transaction } from "@in/server/db/types"
import { encrypt } from "@in/server/modules/encryption/encryption"
import { richMediaDependencies, type MediaDependency } from "@in/server/modules/message/richText"
import { eq } from "drizzle-orm"
import { createHash } from "node:crypto"

type ReplaceMessageRichMediaIndexInput = {
  tx: Transaction
  messageGlobalId: bigint
  chatId: number
  messageId: number
  richText?: RichMessage | null
}

export async function replaceMessageRichMediaIndex(input: ReplaceMessageRichMediaIndexInput): Promise<void> {
  await input.tx.delete(messageRichMedia).where(eq(messageRichMedia.messageGlobalId, input.messageGlobalId))

  if (!input.richText) {
    return
  }

  const rows = richMediaDependencies(input.richText).map((dep) => mediaDependencyRow(input, dep))
  if (rows.length === 0) {
    return
  }

  await input.tx.insert(messageRichMedia).values(rows)
}

function mediaDependencyRow(
  input: Omit<ReplaceMessageRichMediaIndexInput, "tx" | "richText">,
  dep: MediaDependency,
): DbNewMessageRichMedia {
  const base: DbNewMessageRichMedia = {
    messageGlobalId: input.messageGlobalId,
    chatId: input.chatId,
    messageId: input.messageId,
    blockId: dep.blockId,
    blockPath: dep.blockPath,
    sortOrder: dep.sortOrder,
    kind: dep.kind,
    status: dep.kind === "public_url" ? "pending" : "resolved",
  }

  switch (dep.ref.media.oneofKind) {
    case "photoId":
      return { ...base, kind: "photo", photoId: Number(dep.ref.media.photoId) }
    case "videoId":
      return { ...base, kind: "video", videoId: Number(dep.ref.media.videoId) }
    case "documentId":
      return { ...base, kind: "document", documentId: Number(dep.ref.media.documentId) }
    case "voiceId":
      return { ...base, kind: "voice", voiceId: Number(dep.ref.media.voiceId) }
    case "publicUrl": {
      const encrypted = encrypt(dep.ref.media.publicUrl)
      return {
        ...base,
        kind: "public_url",
        status: "pending",
        publicUrlHash: hashPublicUrl(dep.ref.media.publicUrl),
        publicUrl: encrypted.encrypted,
        publicUrlIv: encrypted.iv,
        publicUrlTag: encrypted.authTag,
      }
    }
    default:
      return base
  }
}

function hashPublicUrl(url: string): Buffer {
  return createHash("sha256").update(url).digest()
}
