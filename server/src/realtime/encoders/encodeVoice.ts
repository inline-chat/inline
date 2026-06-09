import { getSignedUrl } from "@in/server/modules/files/path"
import { Voice } from "@inline-chat/protocol/core"
import type { DbFullVoice } from "@in/server/db/models/files"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { pathExtension, resolveVoiceMimeType } from "@in/server/modules/files/voiceMime"
import { Log } from "@in/server/utils/log"

const log = new Log("realtime/encoders/voice")

export const encodeVoice = ({ voice }: { voice: DbFullVoice }): Voice | undefined => {
  const mimeType = resolveVoiceMimeType({
    mimeType: voice.file.mimeType,
    path: voice.file.path,
    allowExtensionFallbackForInvalidMime: true,
  })

  if (!mimeType.ok) {
    log.warn("Skipping voice media with invalid MIME metadata", {
      voiceId: voice.id,
      fileId: voice.fileId,
      reason: mimeType.reason,
      mimeType: mimeType.mimeType ?? null,
      extension: mimeType.extension ?? pathExtension(voice.file.path) ?? null,
    })
    return undefined
  }

  return {
    id: BigInt(voice.id),
    date: encodeDateStrict(voice.date),
    duration: voice.duration ?? 0,
    size: voice.file.fileSize ?? 0,
    mimeType: mimeType.mimeType,
    cdnUrl: voice.file.path ? getSignedUrl(voice.file.path) ?? undefined : undefined,
    waveform: voice.waveform ? new Uint8Array(voice.waveform) : new Uint8Array(),
  }
}
