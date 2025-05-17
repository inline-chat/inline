import type { DbFile, DbUser } from "@in/server/db/schema"
import { User, UserStatus_Status } from "@in/protocol/core"
import { encodeDate } from "@in/server/realtime/encoders/helpers"
import { decrypt } from "@in/server/modules/encryption/encryption"
import { getSignedUrl } from "@in/server/modules/files/path"

export const encodeUser = ({
  user,
  photoFile,
  min = false,
}: {
  user: DbUser
  photoFile?: DbFile
  min?: boolean
}): User => {
  let cdnUrl: string | undefined = undefined
  if (photoFile) {
    const path =
      photoFile.pathEncrypted && photoFile.pathIv && photoFile.pathTag
        ? decrypt({ encrypted: photoFile.pathEncrypted, iv: photoFile.pathIv, authTag: photoFile.pathTag })
        : null

    cdnUrl = path ? getSignedUrl(path) ?? undefined : undefined
  }

  return {
    id: BigInt(user.id),
    username: user.username ?? undefined,
    firstName: user.firstName ?? undefined,
    lastName: user.lastName ?? undefined,
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
    timeZone: user.timeZone ?? undefined,
    profilePhoto: cdnUrl
      ? {
          cdnUrl: cdnUrl,
        }
      : undefined,
  }
}
