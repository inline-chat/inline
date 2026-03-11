import { getSignedUrl } from "@in/server/modules/files/path"
import { Voice } from "@inline-chat/protocol/core"
import type { DbFullVoice } from "@in/server/db/models/files"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"

const defaultMimeType = "audio/ogg"

export const encodeVoice = ({ voice }: { voice: DbFullVoice }): Voice => {
  return {
    id: BigInt(voice.id),
    date: encodeDateStrict(voice.date),
    duration: voice.duration ?? 0,
    size: voice.file.fileSize ?? 0,
    mimeType: voice.file.mimeType ?? defaultMimeType,
    cdnUrl: voice.file.path ? getSignedUrl(voice.file.path) ?? undefined : undefined,
    waveform: voice.waveform ? new Uint8Array(voice.waveform) : new Uint8Array(),
  }
}
