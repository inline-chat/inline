import { db } from "@in/server/db"
import { getFileByUniqueId } from "@in/server/db/models/files"
import { botAvatarAssets } from "@in/server/db/schema"
import { FileTypes } from "@in/server/modules/files/types"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import { BotAvatar_Kind, type SetBotAvatarInput, type SetBotAvatarResult } from "@inline-chat/protocol/core"
import type { FunctionContext } from "./_types"
import { encodeBotWithAvatar, notifyBotAvatarChanged, parseBotUserId, requireManageableBot } from "./bot.avatarHelpers"

export const setBotAvatar = async (
  input: SetBotAvatarInput,
  context: FunctionContext,
): Promise<SetBotAvatarResult> => {
  const botUserId = parseBotUserId(input.botUserId)
  await requireManageableBot(botUserId, context)

  if (input.kind !== BotAvatar_Kind.CODEX_ATLAS) {
    throw RealtimeRpcError.BadRequest()
  }

  const displayName = input.displayName.trim()
  const fileUniqueId = input.fileUniqueId.trim()
  const description = input.description?.trim()

  if (!displayName || !fileUniqueId) {
    throw RealtimeRpcError.BadRequest()
  }

  const file = await getFileByUniqueId(fileUniqueId)
  if (!file || file.userId !== context.currentUserId || file.fileType !== FileTypes.PHOTO) {
    throw RealtimeRpcError.BadRequest()
  }

  await db
    .insert(botAvatarAssets)
    .values({
      botUserId,
      kind: "codex_atlas",
      displayName,
      description: description || null,
      fileId: file.id,
      updatedAt: new Date(),
    })
    .onConflictDoUpdate({
      target: [botAvatarAssets.botUserId],
      set: {
        kind: "codex_atlas",
        displayName,
        description: description || null,
        fileId: file.id,
        updatedAt: new Date(),
      },
    })

  const bot = await encodeBotWithAvatar(botUserId)
  await notifyBotAvatarChanged(botUserId)
  return { bot }
}
