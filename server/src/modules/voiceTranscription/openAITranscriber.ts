import { toFile } from "openai"
import { openaiClient } from "@in/server/libs/openAI"
import { getSignedUrl } from "@in/server/modules/files/path"
import type { DbFullVoice } from "@in/server/db/models/files"
import { Log } from "@in/server/utils/log"
import { resolveVoiceMimeType, type VoiceMimeType } from "@in/server/modules/files/voiceMime"

const log = new Log("modules/voiceTranscription/openAI")
export const voiceTranscriptionModel = "gpt-transcribe"
const fetchTimeoutMs = 30_000

export type VoiceTranscriptionOptions = {
  prompt?: string
  keywords?: string[]
  languages?: string[]
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
  const { request, context } = buildGptTranscribeRequest(file, options)
  log.info("Sending voice transcription request to OpenAI", {
    voiceId: voice.id,
    fileId: voice.fileId,
    model: voiceTranscriptionModel,
    fileSize: voice.file.fileSize ?? null,
    duration: voice.duration ?? null,
    hasPrompt: context.hasPrompt,
    promptLength: context.promptLength,
    keywordCount: context.keywordCount,
    languageHintCount: context.languageHintCount,
  })

  const response = await openaiClient.audio.transcriptions.create(request)

  const text = cleanTranscript(response.text)
  if (!text) {
    log.warn("OpenAI voice transcription returned empty text", {
      voiceId: voice.id,
      fileId: voice.fileId,
      model: voiceTranscriptionModel,
      durationMs: Date.now() - startMs,
    })
    return undefined
  }

  log.info("OpenAI voice transcription completed", {
    voiceId: voice.id,
    fileId: voice.fileId,
    model: voiceTranscriptionModel,
    durationMs: Date.now() - startMs,
    transcriptLength: text.length,
  })

  return text
}

export function buildGptTranscribeRequest(file: File, options?: VoiceTranscriptionOptions) {
  const prompt = options?.prompt?.trim()
  const keywords = normalizeKeywords(options?.keywords)
  const languages = normalizeLanguages(options?.languages)
  const request = {
    file,
    model: voiceTranscriptionModel,
    ...(prompt ? { prompt } : {}),
    ...(keywords.length ? { keywords } : {}),
    ...(languages.length ? { languages } : {}),
    response_format: "json" as const,
    temperature: 0,
  }

  return {
    request,
    context: {
      hasPrompt: Boolean(prompt),
      promptLength: prompt?.length ?? 0,
      keywordCount: keywords.length,
      languageHintCount: languages.length,
    },
  }
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

function normalizeKeywords(values: string[] | undefined): string[] {
  return normalizeContextValues(values, (value) => value.replace(/[<>\r\n]/g, " "))
}

function normalizeLanguages(values: string[] | undefined): string[] {
  return normalizeContextValues(values, (value) => value.toLowerCase())
}

function normalizeContextValues(
  values: string[] | undefined,
  normalize: (value: string) => string,
): string[] {
  const seen = new Set<string>()
  const result: string[] = []

  for (const value of values ?? []) {
    const normalized = normalize(value).replace(/\s+/g, " ").trim()
    const key = normalized.toLowerCase()
    if (!normalized || seen.has(key)) continue
    seen.add(key)
    result.push(normalized)
  }

  return result
}
