import { getSignedUrl } from "@in/server/modules/files/path"
import { Video } from "@in/protocol/core"
import type { DbFullVideo } from "@in/server/db/models/files"
import { encodePhoto } from "@in/server/realtime/encoders/encodePhoto"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

export const encodeVideo = ({ video }: { video: DbFullVideo }) => {
  let proto: Video = {
    id: BigInt(video.id),
    date: encodeDateStrict(video.date),
    w: video.width ?? 0,
    h: video.height ?? 0,
    duration: video.duration ?? 0,
    size: video.file.fileSize ?? 0,
    cdnUrl: video.file?.path ? getSignedUrl(video.file.path) ?? undefined : undefined,
    photo: video.photo ? encodePhoto({ photo: video.photo }) : undefined,
  }

  return proto
}
