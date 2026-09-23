import { getSignedMediaFileProxyUrl } from "@in/server/modules/files/path"
import { Space } from "@inline-chat/protocol/core"
import type { DbSpace } from "@in/server/db/schema"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

// New encoders for Member and MinUser
export function encodeSpace(space: DbSpace, { encodingForUserId }: { encodingForUserId: number }): Space {
  return {
    id: BigInt(space.id),
    name: space.name,
    creator: encodingForUserId === space.creatorId,
    date: encodeDateStrict(space.date),
    isPublic: space.isPublic,
    handle: space.handle ?? undefined,
    seq: space.updateSeq ?? undefined,
    photoFileUniqueId: space.photoFileUniqueId ?? undefined,
    photoUrl: space.photoFileUniqueId ? getSignedMediaFileProxyUrl(space.photoFileUniqueId) ?? undefined : undefined,
    isPro: space.isPro ?? false,
  }
}
