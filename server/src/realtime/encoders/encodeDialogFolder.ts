import type { DialogFolder } from "@inline-chat/protocol/core"
import type { DbDialogFolder } from "@in/server/db/schema"

export function encodeDialogFolder(folder: DbDialogFolder): DialogFolder {
  return {
    id: BigInt(folder.id),
    title: folder.title ?? undefined,
    emoji: folder.emoji ?? undefined,
    order: folder.order,
  }
}
