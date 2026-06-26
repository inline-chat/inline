import { toFile } from "openai"
import { openaiClient } from "@in/server/libs/openAI"
import { getSignedUrl } from "@in/server/modules/files/path"
import type { DbFullVoice } from "@in/server/db/models/files"
import { Log } from "@in/server/utils/log"
import { resolveVoiceMimeType, type VoiceMimeType } from "@in/server/modules/files/voiceMime"

const log = new Log("modules/voiceTranscription/openAI")
const model = "gpt-4o-mini-transcribe"
const fetchTimeoutMs = 30_000

export type VoiceTranscriptionOptions = {
  prompt?: string
}

export type VoiceTranscriber = (voice: DbFullVoice, options?: VoiceTranscriptionOptions) => Promise<string | undefined>

export const transcribeVoiceWithOpenAI: VoiceTranscriber = async (voice, options) => {
  if (!openaiClient) {
    log.warn("Skipping voice transcription: OpenAI client is not configured", {
      voiceId: voice.id,
      fileId: voice.fileId,
    })
    return undefined
  }

  const file = await fetchVoiceFile(voice)
  if (!file) {
    return undefined
  }

  const startMs = Date.now()
  const prompt = options?.prompt?.trim()
  log.info("Sending voice transcription request to OpenAI", {
    voiceId: voice.id,
    fileId: voice.fileId,
    model,
    fileSize: voice.file.fileSize ?? null,
    duration: voice.duration ?? null,
    hasPrompt: Boolean(prompt),
    promptLength: prompt?.length ?? 0,
  })

  const response = await openaiClient.audio.transcriptions.create({
    file,
    model,
    ...(prompt ? { prompt } : {}),
    response_format: "json",
    temperature: 0,
  })

  const text = cleanTranscript(response.text)
  if (!text) {
    log.warn("OpenAI voice transcription returned empty text", {
      voiceId: voice.id,
      fileId: voice.fileId,
      model,
      durationMs: Date.now() - startMs,
    })
    return undefined
  }

  log.info("OpenAI voice transcription completed", {
    voiceId: voice.id,
    fileId: voice.fileId,
    model,
    durationMs: Date.now() - startMs,
    transcriptLength: text.length,
  })

  return text
}

async function fetchVoiceFile(voice: DbFullVoice): Promise<File | undefined> {
  if (!voice.file.path) {
    log.warn("Skipping voice transcription: voice has no file path", {
      voiceId: voice.id,
      fileId: voice.fileId,
    })
    return undefined
  }

  const type = resolveVoiceMimeType({
    mimeType: voice.file.mimeType,
    path: voice.file.path,
    allowExtensionFallbackForInvalidMime: true,
  })
  if (!type.ok) {
    log.warn("Skipping voice transcription: unsupported voice MIME type", {
      voiceId: voice.id,
      fileId: voice.fileId,
      reason: type.reason,
      mimeType: type.mimeType ?? null,
      extension: type.extension ?? null,
    })
    return undefined
  }

  const url = getSignedUrl(voice.file.path, 60 * 10)
  if (!url) {
    log.warn("Skipping voice transcription: signed URL is unavailable", {
      voiceId: voice.id,
      fileId: voice.fileId,
    })
    return undefined
  }

  const response = await fetch(url, { signal: AbortSignal.timeout(fetchTimeoutMs) })
  if (!response.ok) {
    throw new Error(`Failed to fetch voice file for transcription: ${response.status}`)
  }

  const bytes = new Uint8Array(await response.arrayBuffer())
  const name = voiceFileName(voice, type.mimeType)
  return toFile(bytes, name, { type: type.mimeType })
}

function voiceFileName(voice: DbFullVoice, mimeType: VoiceMimeType): string {
  const extension = extensionForMimeType(mimeType)
  return `voice-${voice.id}.${extension}`
}

function extensionForMimeType(mimeType: VoiceMimeType): string {
  switch (mimeType) {
    case "audio/mp4":
    case "audio/x-m4a":
      return "m4a"
    case "audio/ogg":
      return "ogg"
  }
}

function cleanTranscript(text: string | undefined): string | undefined {
  const trimmed = text?.trim()
  return trimmed ? trimmed : undefined
}
