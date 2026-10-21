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
  includeTimeZone = false,
  viewerUserId,
}: {
  user: DbUser
  photoFile?: DbFile
  botAvatar?: DbBotAvatarAsset
  botAvatarFile?: DbFile
  min?: boolean
  includeTimeZone?: boolean
  viewerUserId?: number
}): User => {
  let cdnUrl: string | undefined = undefined
  if (photoFile) {
    cdnUrl = getSignedMediaPhotoUrl(photoFile) ?? undefined
  }

  // Contact details are private to their owner. Only an explicitly identified
  // self view carries them; every other viewer gets the profile without them.
  const includeContact = !min && viewerUserId !== undefined && viewerUserId === user.id

  return {
    id: BigInt(user.id),
    username: user.username ?? undefined,
    firstName: user.firstName ?? undefined,
    lastName: user.lastName ?? undefined,
    bio: min ? undefined : user.bio ?? undefined,
    email: includeContact ? user.email ?? undefined : undefined,
    phoneNumber: includeContact ? user.phoneNumber ?? undefined : undefined,
    pendingSetup: min ? undefined : user.pendingSetup === true ? true : undefined,
    min: min ?? false,
    status: min
      ? undefined
      : {
          online: user.online ? UserStatus_Status.ONLINE : UserStatus_Status.OFFLINE,
          lastOnline: { date: user.lastOnline ? encodeDate(user.lastOnline) : undefined },
        },
    timeZone:
      (min && !includeTimeZone) || (user.shareTimeZone === false && viewerUserId !== user.id)
        ? undefined
        : user.timeZone ?? undefined,
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
