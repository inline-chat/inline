import path from "node:path"
import type { InlineSdkClient, InlineSdkSendMessageMedia } from "@inline-chat/realtime-sdk"
import {
  detectMime,
  extensionForMime,
  loadWebMedia,
  resolveChannelMediaMaxBytes,
  type OpenClawConfig,
} from "openclaw/plugin-sdk"

const DEFAULT_MEDIA_MAX_MB = 20
const SUPPORTED_INLINE_PHOTO_MIME = new Set(["image/jpeg", "image/png", "image/gif"])
const SUPPORTED_INLINE_VIDEO_MIME = new Set(["video/mp4"])
const DEFAULT_VIDEO_WIDTH = 1280
const DEFAULT_VIDEO_HEIGHT = 720
const DEFAULT_VIDEO_DURATION = 1

type InlineUploadType = "photo" | "video" | "document"
type LoadWebMediaCompat = (
  mediaUrl: string,
  maxBytes?: number,
  options?: {
    ssrfPolicy?: unknown
    localRoots?: string[] | "any"
  },
) => Promise<Awaited<ReturnType<typeof loadWebMedia>>>

// openclaw@2026.2.9 types expose only ssrfPolicy, while newer runtimes also support localRoots.
const loadWebMediaCompat = loadWebMedia as unknown as LoadWebMediaCompat

function looksLikeLocalMediaSource(mediaUrl: string): boolean {
  return !/^https?:\/\//i.test(mediaUrl.trim())
}

function normalizeMime(raw: string | undefined): string | undefined {
  const trimmed = raw?.trim().toLowerCase()
  return trimmed || undefined
}

function normalizeExt(rawFileName: string | undefined): string | undefined {
  const ext = path.extname(rawFileName ?? "").trim().toLowerCase()
  if (!ext) return undefined
  return ext.replace(/^\./, "")
}

function isSupportedPhoto(params: { mime?: string; ext?: string }): boolean {
  if (params.mime && SUPPORTED_INLINE_PHOTO_MIME.has(params.mime)) return true
  return params.ext === "jpg" || params.ext === "jpeg" || params.ext === "png" || params.ext === "gif"
}

function isSupportedVideo(params: { mime?: string; ext?: string }): boolean {
  if (params.mime && SUPPORTED_INLINE_VIDEO_MIME.has(params.mime)) return true
  return params.ext === "mp4"
}

function chooseUploadType(params: {
  kind: "image" | "audio" | "video" | "document" | "unknown"
  mime?: string
  ext?: string
}): InlineUploadType {
  // Prefer explicit MIME/extension compatibility when available.
  if (isSupportedPhoto(params)) return "photo"
  if (isSupportedVideo(params)) return "video"

  // Fall back to loader-detected media kind when MIME/extension is unavailable.
  if (params.kind === "image") return "photo"
  if (params.kind === "video") return "video"

  // Fallback to document when Inline media validators would reject the file.
  return "document"
}

function ensureUploadFileName(params: {
  fileName?: string
  uploadType: InlineUploadType
  mime?: string
  ext?: string
}): string {
  const trimmed = params.fileName?.trim()
  if (trimmed) {
    const ext = normalizeExt(trimmed)
    if (ext) return trimmed
  }

  const inferredExt = params.ext ?? extensionForMime(params.mime) ?? undefined
  const fallbackExt =
    inferredExt ??
    (params.uploadType === "photo" ? "jpg" : params.uploadType === "video" ? "mp4" : "bin")
  return `attachment.${fallbackExt}`
}

function resolveMediaMaxBytes(params: {
  cfg: OpenClawConfig
  accountId?: string | null
}): number {
  return (
    resolveChannelMediaMaxBytes({
      cfg: params.cfg,
      ...(params.accountId != null ? { accountId: params.accountId } : {}),
      resolveChannelLimitMb: ({ cfg, accountId }) =>
        cfg.channels?.inline?.accounts?.[accountId]?.mediaMaxMb ??
        cfg.channels?.inline?.mediaMaxMb,
    }) ??
    DEFAULT_MEDIA_MAX_MB * 1024 * 1024
  )
}

function mediaFromUploadResult(params: {
  uploadType: InlineUploadType
  result: {
    photoId?: bigint
    videoId?: bigint
    documentId?: bigint
  }
}): InlineSdkSendMessageMedia {
  if (params.uploadType === "photo" && params.result.photoId != null) {
    return { kind: "photo", photoId: params.result.photoId }
  }
  if (params.uploadType === "video" && params.result.videoId != null) {
    return { kind: "video", videoId: params.result.videoId }
  }
  if (params.result.documentId != null) {
    return { kind: "document", documentId: params.result.documentId }
  }
  throw new Error(`inline media upload: missing ${params.uploadType} id in upload response`)
}

export async function uploadInlineMediaFromUrl(params: {
  client: InlineSdkClient
  cfg: OpenClawConfig
  accountId?: string | null
  mediaUrl: string
}): Promise<InlineSdkSendMessageMedia> {
  const maxBytes = resolveMediaMaxBytes({
    cfg: params.cfg,
    accountId: params.accountId ?? null,
  })
  let loaded: Awaited<ReturnType<typeof loadWebMedia>>
  try {
    loaded = await loadWebMedia(params.mediaUrl, maxBytes)
  } catch (error) {
    const message = String(error)
    const deniedLocalPath = /not under an allowed directory/i.test(message)
    if (!deniedLocalPath || !looksLikeLocalMediaSource(params.mediaUrl)) {
      throw error
    }
    // Match OpenClaw's message-action-runner pattern:
    // localRoots: "any" is used only after sandbox path normalization upstream.
    loaded = await loadWebMediaCompat(params.mediaUrl, maxBytes, {
      localRoots: "any",
    })
  }
  const detectedMime = normalizeMime(
    loaded.contentType ??
      (await detectMime({
        buffer: loaded.buffer,
        ...(loaded.fileName ? { filePath: loaded.fileName } : {}),
      })),
  )
  const normalizedExt = normalizeExt(loaded.fileName)
  const uploadType = chooseUploadType({
    kind: loaded.kind,
    ...(detectedMime ? { mime: detectedMime } : {}),
    ...(normalizedExt ? { ext: normalizedExt } : {}),
  })

  const fileName = ensureUploadFileName({
    ...(loaded.fileName ? { fileName: loaded.fileName } : {}),
    uploadType,
    ...(detectedMime ? { mime: detectedMime } : {}),
    ...(normalizedExt ? { ext: normalizedExt } : {}),
  })
  const upload = await params.client.uploadFile({
    type: uploadType,
    file: loaded.buffer,
    fileName,
    ...(detectedMime ? { contentType: detectedMime } : {}),
    ...(uploadType === "video"
      ? {
          width: DEFAULT_VIDEO_WIDTH,
          height: DEFAULT_VIDEO_HEIGHT,
          duration: DEFAULT_VIDEO_DURATION,
        }
      : {}),
  })

  return mediaFromUploadResult({
    uploadType,
    result: upload,
  })
}
