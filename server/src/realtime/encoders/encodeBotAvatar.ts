import type { BotAvatar } from "@inline-chat/protocol/core"
import { BotAvatar_Kind } from "@inline-chat/protocol/core"
import type { DbBotAvatarAsset, DbFile } from "@in/server/db/schema"
import { getSignedMediaPhotoUrl } from "@in/server/modules/files/path"

export const encodeBotAvatar = ({
  avatar,
  file,
}: {
  avatar: DbBotAvatarAsset
  file: DbFile
}): BotAvatar => ({
  kind: encodeBotAvatarKind(avatar.kind),
  displayName: avatar.displayName,
  description: avatar.description ?? undefined,
  cdnUrl: getSignedMediaPhotoUrl(file) ?? undefined,
  fileUniqueId: file.fileUniqueId,
})

function encodeBotAvatarKind(kind: DbBotAvatarAsset["kind"]): BotAvatar_Kind {
  switch (kind) {
    case "codex_atlas":
      return BotAvatar_Kind.CODEX_ATLAS
  }
}
