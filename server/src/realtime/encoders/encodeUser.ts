import type { DbBotAvatarAsset, DbFile, DbUser } from "@in/server/db/schema"
import { User, UserStatus_Status } from "@inline-chat/protocol/core"
import { encodeDate } from "@in/server/realtime/encoders/helpers"
import { getSignedMediaPhotoUrl } from "@in/server/modules/files/path"
import { encodeBotAvatar } from "@in/server/realtime/encoders/encodeBotAvatar"

export const encodeUser = ({
  user,
  photoFile,
  botAvatar,
  botAvatarFile,
  min = false,
}: {
  user: DbUser
  photoFile?: DbFile
  botAvatar?: DbBotAvatarAsset
  botAvatarFile?: DbFile
  min?: boolean
}): User => {
  let cdnUrl: string | undefined = undefined
  if (photoFile) {
    cdnUrl = getSignedMediaPhotoUrl(photoFile) ?? undefined
  }

  return {
    id: BigInt(user.id),
    username: user.username ?? undefined,
    firstName: user.firstName ?? undefined,
    lastName: user.lastName ?? undefined,
    bio: min ? undefined : user.bio ?? undefined,
    email: min ? undefined : user.email ?? undefined,
    phoneNumber: min ? undefined : user.phoneNumber ?? undefined,
    pendingSetup: min ? undefined : user.pendingSetup === true ? true : undefined,
    min: min ?? false,
    status: min
      ? undefined
      : {
          online: user.online ? UserStatus_Status.ONLINE : UserStatus_Status.OFFLINE,
          lastOnline: { date: user.lastOnline ? encodeDate(user.lastOnline) : undefined },
        },
    timeZone: min ? undefined : user.timeZone ?? undefined,
    bot: user.bot === true ? true : undefined,
    profilePhoto: cdnUrl
      ? {
          cdnUrl: cdnUrl,
          fileUniqueId: photoFile?.fileUniqueId,
        }
      : undefined,
    botAvatar:
      !min && botAvatar && botAvatarFile
        ? encodeBotAvatar({ avatar: botAvatar, file: botAvatarFile })
        : undefined,
  }
}
