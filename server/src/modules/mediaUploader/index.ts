import { lookup as nodeLookup } from "node:dns/promises"
import { isIP } from "node:net"
import {
  type RichBlock,
  type RichMediaRef,
  type RichMessage,
  type RichText,
} from "@inline-chat/protocol/core"
import { isBlockedIp } from "@inline-chat/url-preview"
import { uploadDocument } from "@in/server/modules/files/uploadDocument"
import { uploadPhoto } from "@in/server/modules/files/uploadPhoto"
import { uploadVideo } from "@in/server/modules/files/uploadVideo"
import { uploadVoice } from "@in/server/modules/files/uploadVoice"
import { getSignedMediaPhotoUrl } from "@in/server/modules/files/path"
import type { UploadFileResult } from "@in/server/modules/files/types"
import { validVoiceMimeTypes } from "@in/server/modules/files/voiceMime"
import {
  dbRichMediaPublicUrlFailureStore,
  type RichMediaPublicUrlBackoff,
  type RichMediaPublicUrlFailureStore,
  type RichMediaPublicUrlKind,
} from "@in/server/modules/mediaUploader/publicUrlFailures"
import { normalizeRichMessage } from "@in/server/modules/message/richText"
import { Log } from "@in/server/utils/log"

const log = new Log("modules/mediaUploader")

const imageTypes = new Set(["image/jpeg", "image/png", "image/gif", "image/webp", "image/avif"])
const videoTypes = new Set(["video/mp4"])
const voiceTypes = new Set<string>(validVoiceMimeTypes)
const maxPhotoBytes = 40 * 1024 * 1024
const maxVideoBytes = 200 * 1024 * 1024
const maxDocumentBytes = 200 * 1024 * 1024
const maxVoiceBytes = 20 * 1024 * 1024
const defaultTimeoutMs = 8_000
const defaultMaxRedirects = 4
const defaultUserAgent = "InlineRichMediaUploader/1.0"
const defaultVoiceWaveform = new Uint8Array([128, 128, 128, 128])

type MediaKind = RichMediaPublicUrlKind
type LookupAddress = { address: string; family?: number }
type Lookup = (hostname: string) => Promise<LookupAddress[]>
type ResolveState = {
  resolved: number
  failed: number
  cache: Map<string, Promise<CachedResolution>>
}
type CachedResolution =
  | {
      ok: true
      media: RichMediaRef["media"]
      cdnUrl?: string
      fileUniqueId?: string
    }
  | {
      ok: false
    }
type ResolvedMediaRef = {
  ref: RichMediaRef | undefined
  failedPublicUrl?: string
}

export type ResolveRichMediaPublicUrlsInput = {
  richText: RichMessage
  userId: number
  timeoutMs?: number
  maxRedirects?: number
}

export type ResolveRichMediaPublicUrlsResult = {
  richText: RichMessage
  resolved: number
  failed: number
}

export type MediaFetch = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>

export type MediaUploaderDeps = {
  fetch: MediaFetch
  lookup: Lookup
  photoCdnUrl: (fileUniqueId: string) => string | null
  uploadPhoto: (file: File, context: { userId: number }) => Promise<UploadFileResult>
  uploadVideo: (
    file: File,
    metadata: { width: number; height: number; duration: number; photoId?: bigint },
    context: { userId: number },
  ) => Promise<UploadFileResult>
  uploadVoice: (
    file: File,
    metadata: { duration: number; waveform: Uint8Array },
    context: { userId: number },
  ) => Promise<UploadFileResult>
  uploadDocument: (file: File, photoId: bigint | undefined, context: { userId: number }) => Promise<UploadFileResult>
  failureStore?: RichMediaPublicUrlFailureStore
}

const defaultDeps: MediaUploaderDeps = {
  fetch,
  lookup: defaultLookup,
  photoCdnUrl: getSignedMediaPhotoUrl,
  uploadPhoto,
  uploadVideo,
  uploadVoice,
  uploadDocument,
  failureStore: dbRichMediaPublicUrlFailureStore,
}

export async function resolveRichMediaPublicUrls(
  input: ResolveRichMediaPublicUrlsInput,
  deps: MediaUploaderDeps = defaultDeps,
): Promise<ResolveRichMediaPublicUrlsResult> {
  const richText = structuredClone(input.richText)
  const state: ResolveState = { resolved: 0, failed: 0, cache: new Map() }

  await resolveBlocks(richText.blocks, input, deps, state)

  return {
    richText: normalizeRichMessage(richText),
    resolved: state.resolved,
    failed: state.failed,
  }
}

export function shouldResolveRichMediaUploads(): boolean {
  // Unit tests inject uploader deps directly. Avoid accidental external network calls
  // from high-level send/edit tests while keeping production behavior enabled by default.
  return process.env["NODE_ENV"] !== "test"
}

async function resolveBlocks(
  blocks: RichBlock[],
  input: ResolveRichMediaPublicUrlsInput,
  deps: MediaUploaderDeps,
  state: ResolveState,
): Promise<void> {
  for (let index = 0; index < blocks.length; index += 1) {
    const block = blocks[index]!
    switch (block.block.oneofKind) {
      case "photo": {
        const resolved = await resolveMediaRef(block.block.photo.media, { kind: "photo", input, deps, state })
        block.block.photo.media = resolved.ref
        block.block.photo.caption = captionWithFailedSource(block.block.photo.caption, resolved.failedPublicUrl)
        if (replaceFailedMediaBlock(blocks, index, block.blockId, block.block.photo.caption, resolved)) {
          index -= 1
        }
        break
      }
      case "video": {
        const resolved = await resolveMediaRef(block.block.video.media, {
          kind: "video",
          input,
          deps,
          state,
          width: block.block.video.media?.width,
          height: block.block.video.media?.height,
          duration: block.block.video.duration,
        })
        block.block.video.media = resolved.ref
        block.block.video.caption = captionWithFailedSource(block.block.video.caption, resolved.failedPublicUrl)
        if (replaceFailedMediaBlock(blocks, index, block.blockId, block.block.video.caption, resolved)) {
          index -= 1
        }
        break
      }
      case "document": {
        const resolved = await resolveMediaRef(block.block.document.media, { kind: "document", input, deps, state })
        block.block.document.media = resolved.ref
        block.block.document.caption = captionWithFailedSource(block.block.document.caption, resolved.failedPublicUrl)
        if (replaceFailedMediaBlock(blocks, index, block.blockId, block.block.document.caption, resolved)) {
          index -= 1
        }
        break
      }
      case "audio": {
        const resolved = await resolveMediaRef(block.block.audio.media, {
          kind: "voice",
          input,
          deps,
          state,
          duration: block.block.audio.duration,
        })
        block.block.audio.media = resolved.ref
        block.block.audio.caption = captionWithFailedSource(block.block.audio.caption, resolved.failedPublicUrl)
        if (replaceFailedMediaBlock(blocks, index, block.blockId, block.block.audio.caption, resolved)) {
          index -= 1
        }
        break
      }
      case "embed":
        block.block.embed.poster = (await resolveMediaRef(block.block.embed.poster, { kind: "photo", input, deps, state })).ref
        break
      case "embedPost":
        block.block.embedPost.authorPhoto = (await resolveMediaRef(block.block.embedPost.authorPhoto, {
          kind: "photo",
          input,
          deps,
          state,
        })).ref
        await resolveBlocks(block.block.embedPost.blocks, input, deps, state)
        break
      case "linkPreview":
        block.block.linkPreview.media = (await resolveMediaRef(block.block.linkPreview.media, { kind: "photo", input, deps, state })).ref
        break
      case "collage":
        await resolveBlocks(block.block.collage.items, input, deps, state)
        break
      case "list":
        for (const item of block.block.list.items) {
          await resolveBlocks(item.blocks, input, deps, state)
        }
        break
      case "listItem":
        await resolveBlocks(block.block.listItem.blocks, input, deps, state)
        break
      case "quote":
        await resolveBlocks(block.block.quote.blocks, input, deps, state)
        break
      case "details":
        await resolveBlocks(block.block.details.blocks, input, deps, state)
        break
      case "thinking":
        await resolveBlocks(block.block.thinking.blocks, input, deps, state)
        break
      default:
        break
    }
  }
}

async function resolveMediaRef(
  ref: RichMediaRef | undefined,
  options: {
    kind: MediaKind
    input: ResolveRichMediaPublicUrlsInput
    deps: MediaUploaderDeps
    state: ResolveState
    width?: number
    height?: number
    duration?: number
  },
): Promise<ResolvedMediaRef> {
  if (!ref || ref.media.oneofKind !== "publicUrl") {
    return { ref }
  }

  const publicUrl = ref.media.publicUrl
  const cached = await cachedResolution(ref, options)
  if (cached.ok) {
    options.state.resolved += 1
    return {
      ref: {
        ...ref,
        cdnUrl: cached.cdnUrl ?? ref.cdnUrl,
        fileUniqueId: cached.fileUniqueId ?? ref.fileUniqueId,
        media: cached.media,
      },
    }
  }

  options.state.failed += 1
  return { ref: stripPublicMediaRef(ref), failedPublicUrl: publicUrl }
}

function replaceFailedMediaBlock(
  blocks: RichBlock[],
  index: number,
  blockId: string | undefined,
  caption: RichText[],
  resolved: ResolvedMediaRef,
): boolean {
  if (!resolved.failedPublicUrl || hasResolvedMediaRef(resolved.ref)) {
    return false
  }

  if (caption.length === 0) {
    blocks.splice(index, 1)
    return true
  }

  blocks[index] = {
    blockId: blockId || `failed-media-${index}`,
    block: {
      oneofKind: "paragraph",
      paragraph: { text: caption },
    },
  }
  return false
}

function hasResolvedMediaRef(ref: RichMediaRef | undefined): boolean {
  return Boolean(ref?.media.oneofKind && ref.media.oneofKind !== "publicUrl")
}

function cachedResolution(
  ref: RichMediaRef,
  options: {
    kind: MediaKind
    input: ResolveRichMediaPublicUrlsInput
    deps: MediaUploaderDeps
    state: ResolveState
    width?: number
    height?: number
    duration?: number
  },
): Promise<CachedResolution> {
  const publicUrl = ref.media.oneofKind === "publicUrl" ? ref.media.publicUrl : ""
  const key = resolutionCacheKey(publicUrl, options)
  const existing = options.state.cache.get(key)
  if (existing) {
    return existing
  }

  const resolution = resolveCachedPublicMediaRef(ref, publicUrl, options)
  options.state.cache.set(key, resolution)
  return resolution
}

async function resolveCachedPublicMediaRef(
  ref: RichMediaRef,
  publicUrl: string,
  options: {
    kind: MediaKind
    input: ResolveRichMediaPublicUrlsInput
    deps: MediaUploaderDeps
    width?: number
    height?: number
    duration?: number
  },
): Promise<CachedResolution> {
  const backoff = await activePublicUrlBackoff(publicUrl, options)
  if (backoff) {
    log.debug("Skipping rich media public URL during failure backoff", {
      kind: options.kind,
      userId: options.input.userId,
      urlHost: safeUrlHost(publicUrl),
      failureCount: backoff.failureCount,
      retryAfter: backoff.retryAfter.toISOString(),
    })
    return { ok: false }
  }

  try {
    const resolved = await uploadPublicMediaRef(ref, publicUrl, options)
    await clearPublicUrlFailure(publicUrl, options)
    log.info("Resolved rich media public URL", {
      kind: options.kind,
      userId: options.input.userId,
      urlHost: safeUrlHost(publicUrl),
      fileUniqueId: resolved.fileUniqueId,
      hasCdnUrl: Boolean(resolved.cdnUrl),
    })
    return {
      ok: true,
      media: resolved.media,
      cdnUrl: resolved.cdnUrl,
      fileUniqueId: resolved.fileUniqueId,
    }
  } catch (error) {
    const reason = errorReason(error)
    if (isPublicMediaSourceError(error)) {
      log.info("Degraded rich media public URL to fallback", {
        reason,
        kind: options.kind,
        userId: options.input.userId,
        urlHost: safeUrlHost(publicUrl),
      })
      await recordPublicUrlFailure(publicUrl, reason, options)
    } else {
      log.warn("Failed to resolve rich media public URL", {
        reason,
        kind: options.kind,
        userId: options.input.userId,
        urlHost: safeUrlHost(publicUrl),
      })
    }
    return { ok: false }
  }
}

async function activePublicUrlBackoff(
  publicUrl: string,
  options: {
    kind: MediaKind
    input: ResolveRichMediaPublicUrlsInput
    deps: MediaUploaderDeps
  },
): Promise<RichMediaPublicUrlBackoff | null> {
  const store = options.deps.failureStore
  if (!store) {
    return null
  }

  try {
    return await store.activeBackoff({ kind: options.kind, publicUrl, now: new Date() })
  } catch (error) {
    log.warn("Failed to read rich media public URL backoff", {
      reason: errorReason(error),
      kind: options.kind,
      userId: options.input.userId,
      urlHost: safeUrlHost(publicUrl),
    })
    return null
  }
}

async function recordPublicUrlFailure(
  publicUrl: string,
  reason: string,
  options: {
    kind: MediaKind
    input: ResolveRichMediaPublicUrlsInput
    deps: MediaUploaderDeps
  },
): Promise<void> {
  const store = options.deps.failureStore
  if (!store) {
    return
  }

  try {
    await store.recordFailure({ kind: options.kind, publicUrl, reason, now: new Date() })
  } catch (error) {
    log.warn("Failed to record rich media public URL backoff", {
      reason: errorReason(error),
      kind: options.kind,
      userId: options.input.userId,
      urlHost: safeUrlHost(publicUrl),
    })
  }
}

async function clearPublicUrlFailure(
  publicUrl: string,
  options: {
    kind: MediaKind
    input: ResolveRichMediaPublicUrlsInput
    deps: MediaUploaderDeps
  },
): Promise<void> {
  const store = options.deps.failureStore
  if (!store) {
    return
  }

  try {
    await store.clearFailure({ kind: options.kind, publicUrl })
  } catch (error) {
    log.warn("Failed to clear rich media public URL backoff", {
      reason: errorReason(error),
      kind: options.kind,
      userId: options.input.userId,
      urlHost: safeUrlHost(publicUrl),
    })
  }
}

function resolutionCacheKey(
  publicUrl: string,
  options: {
    kind: MediaKind
    width?: number
    height?: number
    duration?: number
  },
): string {
  return [
    options.kind,
    publicUrl,
    options.width ?? "",
    options.height ?? "",
    options.duration ?? "",
  ].join("\n")
}

function errorReason(error: unknown): string {
  if (error instanceof Error) {
    return error.message
  }
  if (typeof error === "string") {
    return error
  }
  return "unknown error"
}

class PublicMediaSourceError extends Error {
  constructor(message: string, cause: unknown) {
    super(message)
    this.name = "PublicMediaSourceError"
    this.cause = cause
  }
}

function isPublicMediaSourceError(error: unknown): error is PublicMediaSourceError {
  return error instanceof PublicMediaSourceError
}

function publicMediaSourceError(error: unknown): PublicMediaSourceError {
  return new PublicMediaSourceError(errorReason(error), error)
}

async function uploadPublicMediaRef(
  ref: RichMediaRef,
  publicUrl: string,
  options: {
    kind: MediaKind
    input: ResolveRichMediaPublicUrlsInput
    deps: MediaUploaderDeps
    width?: number
    height?: number
    duration?: number
  },
): Promise<RichMediaRef> {
  let fetched: { bytes: Uint8Array; contentType: string; finalUrl: URL }
  try {
    const url = validatePublicUrl(publicUrl)
    fetched = await fetchPublicFile(url, {
      deps: options.deps,
      kind: options.kind,
      maxBytes: maxBytesForKind(options.kind),
      timeoutMs: options.input.timeoutMs ?? defaultTimeoutMs,
      maxRedirects: options.input.maxRedirects ?? defaultMaxRedirects,
    })
  } catch (error) {
    throw publicMediaSourceError(error)
  }

  const fileName = ref.fileName?.trim() || fileNameFromUrl(fetched.finalUrl, fetched.contentType)
  const file = new File([fetched.bytes], fileName, { type: fetched.contentType })

  if (options.kind === "photo") {
    const result = await options.deps.uploadPhoto(file, { userId: options.input.userId })
    if (!result.photoId) {
      throw new Error("photo upload did not return a photo id")
    }
    return {
      ...ref,
      cdnUrl: options.deps.photoCdnUrl(result.fileUniqueId) ?? ref.cdnUrl,
      fileUniqueId: result.fileUniqueId,
      media: { oneofKind: "photoId", photoId: BigInt(result.photoId) },
    }
  }

  if (options.kind === "video" && videoTypes.has(fetched.contentType)) {
    if (!options.width || !options.height || options.duration === undefined) {
      throw new Error("video rich media requires width, height, and duration metadata")
    }
    const result = await options.deps.uploadVideo(
      file,
      { width: options.width, height: options.height, duration: options.duration },
      { userId: options.input.userId },
    )
    if (!result.videoId) {
      throw new Error("video upload did not return a video id")
    }
    return {
      ...ref,
      cdnUrl: result.cdnUrl ?? ref.cdnUrl,
      fileUniqueId: result.fileUniqueId,
      media: { oneofKind: "videoId", videoId: BigInt(result.videoId) },
    }
  }

  if (options.kind === "voice") {
    const result = await options.deps.uploadVoice(
      file,
      { duration: normalizedVoiceDuration(options.duration), waveform: defaultVoiceWaveform },
      { userId: options.input.userId },
    )
    if (!result.voiceId) {
      throw new Error("voice upload did not return a voice id")
    }
    return {
      ...ref,
      cdnUrl: result.cdnUrl ?? ref.cdnUrl,
      fileUniqueId: result.fileUniqueId,
      media: { oneofKind: "voiceId", voiceId: BigInt(result.voiceId) },
    }
  }

  const result = await options.deps.uploadDocument(file, undefined, { userId: options.input.userId })
  if (!result.documentId) {
    throw new Error("document upload did not return a document id")
  }
  return {
    ...ref,
    cdnUrl: result.cdnUrl ?? ref.cdnUrl,
    fileUniqueId: result.fileUniqueId,
    media: { oneofKind: "documentId", documentId: BigInt(result.documentId) },
  }
}

function assertSupportedContentType(kind: MediaKind, contentType: string): void {
  if (kind === "photo" && !imageTypes.has(contentType)) {
    throw new Error(`unsupported photo content type ${contentType}`)
  }

  if (kind === "video" && !videoTypes.has(contentType)) {
    throw new Error(`unsupported video content type ${contentType}`)
  }

  if (kind === "document" && contentType === "text/html") {
    throw new Error("unsupported document content type text/html")
  }

  if (kind === "voice" && !voiceTypes.has(contentType)) {
    throw new Error(`unsupported voice content type ${contentType}`)
  }
}

async function fetchPublicFile(
  url: URL,
  options: { deps: MediaUploaderDeps; kind: MediaKind; maxBytes: number; timeoutMs: number; maxRedirects: number },
): Promise<{ bytes: Uint8Array; contentType: string; finalUrl: URL }> {
  let current = url

  for (let redirectCount = 0; redirectCount <= options.maxRedirects; redirectCount += 1) {
    await assertSafePublicUrl(current, options.deps.lookup)

    const response = await options.deps.fetch(current, {
      redirect: "manual",
      signal: AbortSignal.timeout(options.timeoutMs),
      headers: {
        Accept: acceptHeaderForKind(options.kind),
        "User-Agent": defaultUserAgent,
      },
    })

    if (isRedirectStatus(response.status)) {
      const location = response.headers.get("location")
      if (!location) {
        throw new Error("redirect response missing location")
      }
      current = new URL(location, current)
      continue
    }

    if (!response.ok) {
      throw new Error(`fetch failed with status ${response.status}`)
    }

    const contentLength = response.headers.get("content-length")
    if (contentLengthExceeds(contentLength, options.maxBytes)) {
      throw new Error("remote file exceeds max size")
    }

    const contentType = normalizeContentType(
      response.headers.get("content-type") ?? inferContentTypeFromPath(current.pathname, options.kind),
    )
    if (!contentType) {
      throw new Error("remote file is missing content type")
    }
    assertSupportedContentType(options.kind, contentType)

    const bytes = await readResponseBytes(response, options.maxBytes)
    if (bytes.byteLength === 0) {
      throw new Error("remote file is empty")
    }

    return { bytes, contentType, finalUrl: current }
  }

  throw new Error("too many redirects while fetching remote file")
}

function validatePublicUrl(value: string): URL {
  const url = new URL(value)
  if (url.protocol !== "https:") {
    throw new Error("rich media public URL must use https")
  }
  return url
}

async function assertSafePublicUrl(url: URL, lookup: Lookup): Promise<void> {
  if (url.protocol !== "https:") {
    throw new Error("rich media public URL must use https")
  }
  if (url.username || url.password) {
    throw new Error("rich media public URL must not include credentials")
  }

  const hostname = normalizedHostname(url)
  if (!hostname) {
    throw new Error("rich media public URL host is invalid")
  }
  if (isBlockedLocalHostname(hostname)) {
    throw new Error("rich media public URL host is not allowed")
  }

  if (isIP(hostname) !== 0) {
    if (isBlockedIp(hostname)) {
      throw new Error("rich media public URL resolves to a private or local address")
    }
    return
  }

  let addresses: LookupAddress[]
  try {
    addresses = await lookup(hostname)
  } catch {
    throw new Error("rich media public URL host could not be resolved")
  }

  if (addresses.length === 0) {
    throw new Error("rich media public URL host could not be resolved")
  }
  if (addresses.some((address) => isBlockedIp(address.address))) {
    throw new Error("rich media public URL resolves to a private or local address")
  }
}

async function defaultLookup(hostname: string): Promise<LookupAddress[]> {
  return nodeLookup(hostname, { all: true, verbatim: true })
}

function normalizedHostname(url: URL): string {
  return stripIpv6Brackets(url.hostname).trim().toLowerCase().replace(/\.+$/, "")
}

function stripIpv6Brackets(hostname: string): string {
  return hostname.startsWith("[") && hostname.endsWith("]") ? hostname.slice(1, -1) : hostname
}

function isBlockedLocalHostname(hostname: string): boolean {
  return (
    hostname === "localhost" ||
    hostname.endsWith(".localhost") ||
    hostname.endsWith(".local") ||
    hostname.endsWith(".internal") ||
    hostname.endsWith(".home.arpa")
  )
}

function isRedirectStatus(status: number): boolean {
  return status === 301 || status === 302 || status === 303 || status === 307 || status === 308
}

function acceptHeaderForKind(kind: MediaKind): string {
  switch (kind) {
    case "photo":
      return "image/avif,image/webp,image/png,image/jpeg,image/gif,image/*;q=0.8,*/*;q=0.1"
    case "video":
      return "video/mp4,video/*;q=0.8,*/*;q=0.1"
    case "voice":
      return "audio/ogg,audio/mp4,audio/x-m4a,audio/*;q=0.8,*/*;q=0.1"
    case "document":
      return "application/pdf,application/octet-stream;q=0.8,*/*;q=0.1"
  }
}

function contentLengthExceeds(value: string | null, maxBytes: number): boolean {
  if (!value) {
    return false
  }
  const parsed = Number(value)
  return Number.isFinite(parsed) && parsed > maxBytes
}

async function readResponseBytes(response: Response, maxBytes: number): Promise<Uint8Array> {
  if (!response.body) {
    const bytes = new Uint8Array(await response.arrayBuffer())
    if (bytes.byteLength > maxBytes) {
      throw new Error("remote file exceeds max size")
    }
    return bytes
  }

  const reader = response.body.getReader()
  const chunks: Uint8Array[] = []
  let total = 0

  while (true) {
    const { done, value } = await reader.read()
    if (done) {
      break
    }
    if (!value) {
      continue
    }

    total += value.byteLength
    if (total > maxBytes) {
      await reader.cancel().catch(() => undefined)
      throw new Error("remote file exceeds max size")
    }
    chunks.push(value)
  }

  const output = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    output.set(chunk, offset)
    offset += chunk.byteLength
  }
  return output
}

function maxBytesForKind(kind: MediaKind): number {
  switch (kind) {
    case "photo":
      return maxPhotoBytes
    case "video":
      return maxVideoBytes
    case "voice":
      return maxVoiceBytes
    case "document":
      return maxDocumentBytes
  }
}

function normalizeContentType(value: string): string | undefined {
  const [type] = value.split(";")
  const normalized = type?.trim().toLowerCase()
  return normalized || undefined
}

function inferContentTypeFromPath(path: string, kind: MediaKind): string {
  const extension = path.split(".").pop()?.toLowerCase()
  switch (extension) {
    case "jpg":
    case "jpeg":
      return "image/jpeg"
    case "png":
      return "image/png"
    case "gif":
      return "image/gif"
    case "webp":
      return "image/webp"
    case "avif":
      return "image/avif"
    case "mp4":
      if (kind === "voice") {
        return "audio/mp4"
      }
      return "video/mp4"
    case "m4a":
      return "audio/mp4"
    case "ogg":
    case "oga":
      return "audio/ogg"
    case "pdf":
      return "application/pdf"
    default:
      return "application/octet-stream"
  }
}

function fileNameFromUrl(url: URL, contentType: string): string {
  const rawName = decodeURIComponent(url.pathname.split("/").pop() || "")
  if (rawName && rawName.includes(".")) {
    return rawName
  }
  return `rich-media.${extensionForContentType(contentType)}`
}

function extensionForContentType(contentType: string): string {
  switch (contentType) {
    case "image/jpeg":
      return "jpg"
    case "image/png":
      return "png"
    case "image/gif":
      return "gif"
    case "image/webp":
      return "webp"
    case "image/avif":
      return "avif"
    case "video/mp4":
      return "mp4"
    case "audio/ogg":
      return "ogg"
    case "audio/mp4":
    case "audio/x-m4a":
      return "m4a"
    case "application/pdf":
      return "pdf"
    default:
      return "bin"
  }
}

function normalizedVoiceDuration(duration: number | undefined): number {
  if (duration === undefined || !Number.isFinite(duration) || duration < 0) {
    return 0
  }
  return Math.trunc(duration)
}

function safeUrlHost(value: string): string | undefined {
  try {
    return new URL(value).host
  } catch {
    return undefined
  }
}

function stripPublicMediaRef(ref: RichMediaRef): RichMediaRef {
  return {
    ...ref,
    media: { oneofKind: undefined },
  }
}

function captionWithFailedSource(caption: RichText[], failedPublicUrl: string | undefined): RichText[] {
  const sourceUrl = safeSourceUrl(failedPublicUrl)
  if (!sourceUrl || richTextContains(caption, sourceUrl)) {
    return caption
  }

  const source: RichText[] = [
    { text: "Source: ", children: [], styles: [] },
    { text: sourceUrl, children: [], styles: [], url: sourceUrl },
  ]
  if (caption.length === 0) {
    return source
  }

  return [
    ...caption,
    { text: "\n", children: [], styles: [] },
    ...source,
  ]
}

function safeSourceUrl(value: string | undefined): string | undefined {
  if (!value) {
    return undefined
  }

  let url: URL
  try {
    url = new URL(value)
  } catch {
    return undefined
  }

  if (url.protocol !== "https:" || url.username || url.password) {
    return undefined
  }

  const hostname = normalizedHostname(url)
  if (!hostname || isBlockedLocalHostname(hostname)) {
    return undefined
  }
  if (isIP(hostname) !== 0 && isBlockedIp(hostname)) {
    return undefined
  }

  return url.toString()
}

function richTextContains(nodes: RichText[], needle: string): boolean {
  for (const node of nodes) {
    if (node.text?.includes(needle) || node.url === needle || richTextContains(node.children ?? [], needle)) {
      return true
    }
  }
  return false
}
