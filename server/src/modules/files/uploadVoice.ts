import { db } from "@in/server/db"
import { voices } from "@in/server/db/schema"
import { getVoiceMetadataAndValidate } from "@in/server/modules/files/metadata"
import { FileTypes, type UploadFileResult } from "@in/server/modules/files/types"
import { Log } from "@in/server/utils/log"
import { uploadFile } from "./uploadAFile"

const log = new Log("modules/files/uploadVoice")

interface VoiceMetadata {
  duration: number
  waveform: Uint8Array
}

export async function uploadVoice(
  file: File,
  inputMetadata: VoiceMetadata,
  context: { userId: number },
): Promise<UploadFileResult> {
  try {
    const metadata = await getVoiceMetadataAndValidate(file, inputMetadata.duration, inputMetadata.waveform)
    const { dbFile, fileUniqueId } = await uploadFile(file, FileTypes.VOICE, metadata, context)

    const [voice] = await db
      .insert(voices)
      .values({
        fileId: dbFile.id,
        duration: metadata.duration,
        waveform: Buffer.from(metadata.waveform),
        date: new Date(),
      })
      .returning()

    if (!voice) {
      throw new Error("Failed to save voice to DB")
    }

    return { fileUniqueId, voiceId: voice.id }
  } catch (error) {
    log.error("Voice upload failed", {
      error,
      userId: context.userId,
      duration: inputMetadata.duration,
      waveformLength: inputMetadata.waveform.length,
      fileName: file.name,
      fileSize: file.size,
      mimeType: file.type,
    })
    throw error
  }
}
