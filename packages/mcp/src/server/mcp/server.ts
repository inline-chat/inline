import { Buffer } from "node:buffer"
import { lookup } from "node:dns/promises"
import { isIP } from "node:net"
import * as z from "zod/v4"
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { AuthInfo } from "@modelcontextprotocol/sdk/server/auth/types.js"
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import type { McpGrant } from "./grant"
import { MessageEntity_Type, type Message, type UrlPreview } from "@inline-chat/protocol/core"
import type {
  InlineApi,
  InlineConversationCandidate,
  InlineConversationDetails,
  InlineEligibleChat,
  InlineMessageContentFilter,
  InlinePersonCandidate,
  InlinePersonSummary,
  InlineSpaceSummary,
  InlineSearchMessagesResult,
  InlineUploadedMediaKind,
} from "../inline/inline-api"
import { logMessagesSendAudit } from "./audit-log"

const MAX_UPLOAD_BYTES = 25 * 1024 * 1024
const MAX_UPLOAD_REDIRECTS = 3
const UPLOAD_FETCH_TIMEOUT_MS = 15_000
const SUPPORTED_PHOTO_MIME = new Set(["image/jpeg", "image/png", "image/gif", "image/webp"])
const SUPPORTED_VIDEO_MIME = new Set(["video/mp4"])
const DEFAULT_RESOURCE_METADATA_URL = "https://mcp.inline.chat/.well-known/oauth-protected-resource"
const INLINE_MCP_INSTRUCTIONS =
  "Inline MCP gives scoped access to the user's work chats. Resolve people, spaces, or thread names with people.search, spaces.list, and conversations.list before using chatId; inspect a target with conversations.get; read context with messages.list/search/context/unread; send only after the target is clear. IDs are strings. Time filters accept today, yesterday, 2d ago, YYYY-MM-DD, or epoch seconds. Use account.me to inspect scopes and allowed chat contexts."

type RequestedUploadKind = "auto" | InlineUploadedMediaKind

type ResolvedUploadSource = {
  sourceKind: "base64" | "url"
  bytes: Uint8Array
  inferredContentType?: string
  inferredFileName?: string
  sourceRef: string | null
}

type SendMode = "normal" | "silent"
type ConversationSort = "relevance" | "recent" | "unread"

type SendBatchItem =
  | {
      type: "text"
      text: string
      replyToMsgId?: string
      sendMode?: SendMode
    }
  | {
      type: "media"
      mediaKind: InlineUploadedMediaKind
      mediaId: string
      text?: string
      replyToMsgId?: string
      sendMode?: SendMode
    }

class InsufficientScopeError extends Error {
  constructor(readonly neededScope: string) {
    super(`Authorization scope missing: this tool requires ${neededScope}. Re-authorize Inline MCP with that scope and try again.`)
  }
}

function requireScope(scopes: string[], needed: string): void {
  if (!scopes.includes(needed)) {
    throw new InsufficientScopeError(needed)
  }
}

function jsonText(obj: unknown): { type: "text"; text: string } {
  return { type: "text", text: JSON.stringify(obj) }
}

function escapeAuthParam(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
}

function wwwAuthenticateChallenge(resourceMetadataUrl: string, scope: string): string {
  return `Bearer resource_metadata="${escapeAuthParam(resourceMetadataUrl)}", error="insufficient_scope", error_description="Inline MCP requires ${escapeAuthParam(
    scope,
  )}.", scope="${escapeAuthParam(scope)}"`
}

function toolExecutionError(error: unknown, resourceMetadataUrl: string): CallToolResult {
  const message = error instanceof Error ? error.message : String(error)
  const result: CallToolResult = {
    isError: true,
    content: [{ type: "text", text: message }],
  }
  if (error instanceof InsufficientScopeError) {
    result._meta = {
      "mcp/www_authenticate": [wwwAuthenticateChallenge(resourceMetadataUrl, error.neededScope)],
    }
  }
  return result
}

type InlineToolConfig = Record<string, unknown>
type InlineToolHandler = (args: any, extra: { authInfo?: AuthInfo }) => Promise<CallToolResult>

function registerInlineTool(
  server: McpServer,
  resourceMetadataUrl: string,
  name: string,
  config: InlineToolConfig,
  cb: InlineToolHandler,
): void {
  ;(server.registerTool as any)(name, config, async (args: any, extra: any) => {
    try {
      return await cb(args, extra as { authInfo?: AuthInfo })
    } catch (error) {
      return toolExecutionError(error, resourceMetadataUrl)
    }
  })
}

function toolMeta(scopes: string[], invoking: string, invoked: string): Record<string, unknown> {
  return {
    securitySchemes: [{ type: "oauth2", scopes }],
    "openai/toolInvocation/invoking": invoking,
    "openai/toolInvocation/invoked": invoked,
  }
}

function snippetOf(text: string | null | undefined, max = 200): string | undefined {
  if (!text) return undefined
  const cleaned = text.replace(/\s+/g, " ").trim()
  if (!cleaned) return undefined
  return cleaned.length > max ? `${cleaned.slice(0, Math.max(0, max - 3))}...` : cleaned
}

function sourceTitle(title: string | null | undefined, chatId: bigint): string {
  const cleaned = (title ?? "").trim()
  return cleaned.length > 0 ? cleaned : `chat ${chatId.toString()}`
}

function userUri(userId: bigint): string {
  return `inline://user/${userId.toString()}`
}

function chatUri(chatId: bigint): string {
  return `inline://chat/${chatId.toString()}`
}

function messageUri(chatId: bigint, messageId: bigint): string {
  return `${chatUri(chatId)}/message/${messageId.toString()}`
}

function parseInlineId(input: string, field: string): bigint {
  try {
    const id = BigInt(input)
    if (id <= 0n) throw new Error(`invalid ${field}`)
    return id
  } catch {
    throw new Error(`invalid ${field}`)
  }
}

function parseChatId(input: string): bigint {
  return parseInlineId(input, "chatId")
}

function parseUserId(input: string): bigint {
  return parseInlineId(input, "userId")
}

function parseIntegerSeconds(input: string): bigint | null {
  if (!/^\d+$/.test(input)) return null
  try {
    return BigInt(input)
  } catch {
    return null
  }
}

function startOfLocalDay(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate(), 0, 0, 0, 0)
}

function endOfLocalDay(date: Date): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate(), 23, 59, 59, 999)
}

function parseRelativeAgo(raw: string): bigint | null {
  const match = raw.match(/^(\d+)\s*([smhdw])\s*ago$/i)
  if (!match) return null
  const amount = Number(match[1])
  const unit = match[2].toLowerCase()
  const seconds =
    unit === "s"
      ? amount
      : unit === "m"
        ? amount * 60
        : unit === "h"
          ? amount * 60 * 60
          : unit === "d"
            ? amount * 60 * 60 * 24
            : amount * 60 * 60 * 24 * 7
  return BigInt(Math.floor(Date.now() / 1000) - seconds)
}

function parseTimeInput(raw: string | undefined, kind: "since" | "until"): bigint | undefined {
  const value = raw?.trim().toLowerCase()
  if (!value) return undefined

  const now = new Date()
  if (value === "today") {
    const date = kind === "since" ? startOfLocalDay(now) : endOfLocalDay(now)
    return BigInt(Math.floor(date.getTime() / 1000))
  }
  if (value === "yesterday") {
    const base = new Date(now)
    base.setDate(base.getDate() - 1)
    const date = kind === "since" ? startOfLocalDay(base) : endOfLocalDay(base)
    return BigInt(Math.floor(date.getTime() / 1000))
  }

  const relative = parseRelativeAgo(value)
  if (relative != null) return relative

  const integerSeconds = parseIntegerSeconds(value)
  if (integerSeconds != null) return integerSeconds

  const dayOnlyMatch = value.match(/^(\d{4})-(\d{2})-(\d{2})$/)
  if (dayOnlyMatch) {
    const year = Number(dayOnlyMatch[1])
    const month = Number(dayOnlyMatch[2]) - 1
    const day = Number(dayOnlyMatch[3])
    const date = kind === "since" ? new Date(year, month, day, 0, 0, 0, 0) : new Date(year, month, day, 23, 59, 59, 999)
    if (!Number.isNaN(date.getTime())) {
      return BigInt(Math.floor(date.getTime() / 1000))
    }
  }

  const parsed = new Date(value)
  if (!Number.isNaN(parsed.getTime())) {
    return BigInt(Math.floor(parsed.getTime() / 1000))
  }

  throw new Error(`invalid ${kind} value`)
}

function parseContentFilter(raw: string | undefined): InlineMessageContentFilter {
  switch ((raw ?? "all").toLowerCase()) {
    case "all":
      return "all"
    case "links":
      return "links"
    case "media":
      return "media"
    case "photos":
      return "photos"
    case "videos":
      return "videos"
    case "documents":
      return "documents"
    case "files":
      return "files"
    default:
      throw new Error("invalid content filter")
  }
}

function parseConversationSort(raw: string | undefined, hasQuery: boolean): ConversationSort {
  switch ((raw ?? (hasQuery ? "relevance" : "recent")).toLowerCase()) {
    case "relevance":
      return "relevance"
    case "recent":
      return "recent"
    case "unread":
      return "unread"
    default:
      throw new Error("invalid conversation sort")
  }
}

function parseTarget(args: { chatId?: string; userId?: string }, context: string): { chatId?: bigint; userId?: bigint } {
  const hasChatId = !!args.chatId
  const hasUserId = !!args.userId
  if (hasChatId === hasUserId) {
    throw new Error(`${context}: provide exactly one of chatId or userId`)
  }
  if (hasChatId) return { chatId: parseChatId(args.chatId!) }
  return { userId: parseUserId(args.userId!) }
}

function coerceBigIntArray(values: string[] | undefined, field: string): bigint[] {
  const out: bigint[] = []
  for (const value of values ?? []) {
    try {
      out.push(BigInt(value))
    } catch {
      throw new Error(`invalid ${field}`)
    }
  }
  return out
}

function normalizeMime(raw: string | undefined): string | undefined {
  const trimmed = raw?.trim().toLowerCase()
  return trimmed || undefined
}

function normalizeExt(rawFileName: string | undefined): string | undefined {
  const leaf = sanitizeFileName(rawFileName)
  const idx = leaf.lastIndexOf(".")
  if (idx <= 0 || idx === leaf.length - 1) return undefined
  return leaf.slice(idx + 1).trim().toLowerCase() || undefined
}

function sanitizeFileName(raw: string | undefined): string {
  const trimmed = raw?.trim()
  if (!trimmed) return ""
  const normalized = trimmed.replace(/\\/g, "/")
  const leaf = normalized.split("/").pop() ?? normalized
  const noQuery = leaf.split(/[?#]/, 1)[0] ?? leaf
  const sanitized = stripControlCharacters(noQuery).trim()
  return sanitized
}

function stripControlCharacters(value: string): string {
  let out = ""
  for (const char of value) {
    const code = char.charCodeAt(0)
    if (code <= 0x1f || code === 0x7f) continue
    out += char
  }
  return out
}

function ensureUploadFileName(input: string | undefined, type: InlineUploadedMediaKind, contentType: string | undefined): string {
  const safe = sanitizeFileName(input)
  if (safe) return safe
  const fallbackExt =
    normalizeExt(input) ??
    (contentType === "image/png"
      ? "png"
      : contentType === "image/gif"
        ? "gif"
        : contentType === "image/webp"
          ? "webp"
          : type === "photo"
            ? "jpg"
            : type === "video"
              ? "mp4"
              : "bin")
  return `attachment.${fallbackExt}`
}

function isSupportedPhoto(params: { mime?: string; ext?: string }): boolean {
  if (params.mime && SUPPORTED_PHOTO_MIME.has(params.mime)) return true
  return params.ext === "jpg" || params.ext === "jpeg" || params.ext === "png" || params.ext === "gif" || params.ext === "webp"
}

function isSupportedVideo(params: { mime?: string; ext?: string }): boolean {
  if (params.mime && SUPPORTED_VIDEO_MIME.has(params.mime)) return true
  return params.ext === "mp4"
}

function chooseUploadType(params: { requestedKind: RequestedUploadKind; mime?: string; fileName?: string }): InlineUploadedMediaKind {
  if (params.requestedKind !== "auto") return params.requestedKind
  const ext = normalizeExt(params.fileName)
  if (isSupportedPhoto({ mime: params.mime, ext })) return "photo"
  if (isSupportedVideo({ mime: params.mime, ext })) return "video"
  return "document"
}

function parseUploadKind(raw: string | undefined): RequestedUploadKind {
  switch ((raw ?? "auto").toLowerCase()) {
    case "auto":
      return "auto"
    case "photo":
      return "photo"
    case "video":
      return "video"
    case "document":
      return "document"
    default:
      throw new Error("invalid upload kind")
  }
}

function parseContentTypeArg(raw: string | undefined): string | undefined {
  return normalizeMime(raw)
}

function parsePositiveInt(raw: number | undefined, field: string): number | undefined {
  if (raw == null) return undefined
  if (!Number.isFinite(raw) || !Number.isInteger(raw) || raw <= 0) {
    throw new Error(`${field} must be a positive integer`)
  }
  return raw
}

function parseBase64Payload(raw: string): { bytes: Uint8Array; contentType?: string } {
  const trimmed = raw.trim()
  if (!trimmed) throw new Error("base64 payload is empty")

  let base64Data = trimmed
  let contentType: string | undefined
  const dataUrlMatch = trimmed.match(/^data:([^,]*?),(.*)$/is)
  if (dataUrlMatch) {
    const metadata = dataUrlMatch[1] ?? ""
    if (!/;base64(?:;|$)/i.test(metadata)) {
      throw new Error("data URL payload must be base64-encoded")
    }
    const mediaType = metadata.split(";", 1)[0]?.trim()
    contentType = normalizeMime(mediaType)
    base64Data = dataUrlMatch[2] ?? ""
  }

  const normalized = base64Data.replace(/\s+/g, "").replace(/-/g, "+").replace(/_/g, "/")
  if (!normalized) throw new Error("base64 payload is empty")
  if (normalized.length % 4 === 1 || /[^A-Za-z0-9+/=]/.test(normalized)) {
    throw new Error("invalid base64 payload")
  }

  const approxBytes = Math.floor((normalized.length * 3) / 4)
  if (approxBytes > MAX_UPLOAD_BYTES + 8) {
    throw new Error(`file exceeds ${MAX_UPLOAD_BYTES} bytes limit`)
  }

  let bytes: Buffer
  try {
    bytes = Buffer.from(normalized, "base64")
  } catch {
    throw new Error("invalid base64 payload")
  }
  if (bytes.byteLength === 0) throw new Error("decoded file is empty")
  if (bytes.byteLength > MAX_UPLOAD_BYTES) {
    throw new Error(`file exceeds ${MAX_UPLOAD_BYTES} bytes limit`)
  }
  return {
    bytes: new Uint8Array(bytes),
    ...(contentType ? { contentType } : {}),
  }
}

function parseIpv4(address: string): number[] | null {
  const parts = address.split(".")
  if (parts.length !== 4) return null
  const octets: number[] = []
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null
    const octet = Number(part)
    if (!Number.isInteger(octet) || octet < 0 || octet > 255) return null
    octets.push(octet)
  }
  return octets
}

function isPrivateIpv4(address: string): boolean {
  const octets = parseIpv4(address)
  if (!octets) return true
  const [a, b] = octets
  if (a === 10) return true
  if (a === 127) return true
  if (a === 169 && b === 254) return true
  if (a === 172 && b >= 16 && b <= 31) return true
  if (a === 192 && b === 168) return true
  if (a === 100 && b >= 64 && b <= 127) return true
  if (a === 0) return true
  if (a >= 224) return true
  return false
}

function isPrivateIpv6(address: string): boolean {
  const lowered = address.toLowerCase().split("%", 1)[0] ?? ""
  if (!lowered) return true
  if (lowered === "::" || lowered === "::1") return true
  if (lowered.startsWith("fc") || lowered.startsWith("fd")) return true
  if (lowered.startsWith("fe8") || lowered.startsWith("fe9") || lowered.startsWith("fea") || lowered.startsWith("feb")) return true
  if (lowered.startsWith("ff")) return true
  if (lowered.startsWith("2001:db8")) return true
  const mappedV4 = lowered.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/)
  if (mappedV4) return isPrivateIpv4(mappedV4[1] ?? "")
  return false
}

function isPrivateAddress(address: string): boolean {
  const ipVersion = isIP(address)
  if (ipVersion === 4) return isPrivateIpv4(address)
  if (ipVersion === 6) return isPrivateIpv6(address)
  return true
}

async function assertSafeRemoteUrl(url: URL): Promise<void> {
  if (url.protocol !== "https:") {
    throw new Error("url must use https")
  }
  if (url.username || url.password) {
    throw new Error("url must not include credentials")
  }

  const hostname = url.hostname.trim().toLowerCase().replace(/\.+$/, "")
  if (!hostname) throw new Error("invalid url hostname")
  if (hostname === "localhost" || hostname.endsWith(".localhost") || hostname.endsWith(".local")) {
    throw new Error("url host is not allowed")
  }

  if (isIP(hostname)) {
    if (isPrivateAddress(hostname)) {
      throw new Error("url host resolves to a private or local address")
    }
    return
  }

  let resolved: { address: string }[]
  try {
    resolved = await lookup(hostname, { all: true, verbatim: true })
  } catch {
    throw new Error("unable to resolve url host")
  }
  if (resolved.length === 0) throw new Error("unable to resolve url host")
  for (const address of resolved) {
    if (isPrivateAddress(address.address)) {
      throw new Error("url host resolves to a private or local address")
    }
  }
}

function isRedirectStatus(status: number): boolean {
  return status === 301 || status === 302 || status === 303 || status === 307 || status === 308
}

function parseContentDispositionFileName(raw: string | null): string | undefined {
  if (!raw) return undefined
  const starMatch = raw.match(/filename\*\s*=\s*([^;]+)/i)
  if (starMatch) {
    const token = starMatch[1]?.trim().replace(/^"|"$/g, "")
    const encoded = token?.includes("''") ? token.split("''", 2)[1] : token
    if (encoded) {
      try {
        const decoded = decodeURIComponent(encoded)
        const safe = sanitizeFileName(decoded)
        if (safe) return safe
      } catch {
      }
    }
  }
  const directMatch = raw.match(/filename\s*=\s*("?)([^";]+)\1/i)
  if (directMatch) {
    const safe = sanitizeFileName(directMatch[2])
    if (safe) return safe
  }
  return undefined
}

function fileNameFromUrl(url: URL): string | undefined {
  const segments = url.pathname.split("/").filter(Boolean)
  const leaf = segments[segments.length - 1]
  if (!leaf) return undefined
  const decoded = (() => {
    try {
      return decodeURIComponent(leaf)
    } catch {
      return leaf
    }
  })()
  const safe = sanitizeFileName(decoded)
  return safe || undefined
}

function redactUrl(raw: URL): string {
  const url = new URL(raw.toString())
  url.username = ""
  url.password = ""
  url.search = ""
  url.hash = ""
  return url.toString()
}

async function readResponseBytesLimited(response: Response, maxBytes: number): Promise<Uint8Array> {
  const body = response.body
  if (!body) return new Uint8Array()
  const reader = body.getReader()
  const chunks: Uint8Array[] = []
  let total = 0

  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    if (!value) continue
    total += value.byteLength
    if (total > maxBytes) {
      try {
        await reader.cancel("file_too_large")
      } catch {
      }
      throw new Error(`file exceeds ${maxBytes} bytes limit`)
    }
    chunks.push(value)
  }

  const out = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    out.set(chunk, offset)
    offset += chunk.byteLength
  }
  return out
}

async function loadUploadSourceFromUrl(urlInput: string): Promise<ResolvedUploadSource> {
  let current: URL
  try {
    current = new URL(urlInput)
  } catch {
    throw new Error("invalid url")
  }

  for (let redirectCount = 0; redirectCount <= MAX_UPLOAD_REDIRECTS; redirectCount++) {
    await assertSafeRemoteUrl(current)
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), UPLOAD_FETCH_TIMEOUT_MS)
    let response: Response
    try {
      response = await fetch(current, {
        method: "GET",
        redirect: "manual",
        signal: controller.signal,
        headers: {
          accept: "*/*",
        },
      })
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      throw new Error(`failed to fetch url source (${message})`)
    } finally {
      clearTimeout(timeout)
    }

    if (isRedirectStatus(response.status)) {
      const location = response.headers.get("location")
      if (!location) throw new Error("redirect response missing location header")
      current = new URL(location, current)
      continue
    }

    if (!response.ok) {
      throw new Error(`url source responded with status ${response.status}`)
    }

    const contentLengthHeader = response.headers.get("content-length")
    if (contentLengthHeader) {
      const parsed = Number(contentLengthHeader)
      if (Number.isFinite(parsed) && parsed > MAX_UPLOAD_BYTES) {
        throw new Error(`file exceeds ${MAX_UPLOAD_BYTES} bytes limit`)
      }
    }

    const bytes = await readResponseBytesLimited(response, MAX_UPLOAD_BYTES)
    if (bytes.byteLength === 0) throw new Error("downloaded file is empty")

    const inferredContentType = normalizeMime(response.headers.get("content-type")?.split(";", 1)[0] ?? undefined)
    const inferredFileName = parseContentDispositionFileName(response.headers.get("content-disposition")) ?? fileNameFromUrl(current)

    return {
      sourceKind: "url",
      bytes,
      ...(inferredContentType ? { inferredContentType } : {}),
      ...(inferredFileName ? { inferredFileName } : {}),
      sourceRef: redactUrl(current),
    }
  }

  throw new Error("too many redirects while fetching url source")
}

async function resolveUploadSource(params: { base64?: string; url?: string }): Promise<ResolvedUploadSource> {
  const hasBase64 = !!params.base64
  const hasUrl = !!params.url
  if (hasBase64 === hasUrl) {
    throw new Error("provide exactly one of base64 or url")
  }

  if (hasBase64) {
    const parsed = parseBase64Payload(params.base64 ?? "")
    return {
      sourceKind: "base64",
      bytes: parsed.bytes,
      ...(parsed.contentType ? { inferredContentType: parsed.contentType } : {}),
      sourceRef: null,
    }
  }

  return await loadUploadSourceFromUrl(params.url ?? "")
}

function extractMessageUrls(message: Message): string[] {
  const urls = new Set<string>()
  for (const entity of message.entities?.entities ?? []) {
    if (entity.type === MessageEntity_Type.URL || entity.type === MessageEntity_Type.TEXT_URL) {
      if (entity.entity.oneofKind === "textUrl") {
        const candidate = entity.entity.textUrl.url?.trim()
        if (candidate) urls.add(candidate)
      } else if (typeof message.message === "string") {
        const offset = Number(entity.offset)
        const length = Number(entity.length)
        if (Number.isFinite(offset) && Number.isFinite(length) && offset >= 0 && length > 0) {
          const candidate = message.message.slice(offset, offset + length).trim()
          if (candidate) urls.add(candidate)
        }
      }
    }
  }
  for (const attachment of message.attachments?.attachments ?? []) {
    if (attachment.attachment.oneofKind === "urlPreview") {
      const candidate = attachment.attachment.urlPreview.url?.trim()
      if (candidate) urls.add(candidate)
    }
  }
  return Array.from(urls)
}

function bestPhotoSize(photo: { sizes: Array<{ w: number; h: number; size: number; cdnUrl?: string }> }): {
  cdnUrl: string | null
  width: number | null
  height: number | null
  sizeBytes: number | null
} {
  let best: { cdnUrl: string | null; width: number | null; height: number | null; sizeBytes: number | null } = {
    cdnUrl: null,
    width: null,
    height: null,
    sizeBytes: null,
  }
  let bestArea = -1
  for (const size of photo.sizes ?? []) {
    const area = Math.max(0, size.w) * Math.max(0, size.h)
    if (size.cdnUrl && area >= bestArea) {
      bestArea = area
      best = {
        cdnUrl: size.cdnUrl,
        width: size.w,
        height: size.h,
        sizeBytes: size.size ?? null,
      }
    }
  }
  return best
}

function messageMediaSummary(message: Message):
  | {
      kind: "photo" | "video" | "document" | "voice" | "nudge"
      id: string | null
      url: string | null
      fileName?: string | null
      mimeType?: string | null
      sizeBytes?: number | null
      width?: number | null
      height?: number | null
      durationSeconds?: number | null
    }
  | null {
  const media = message.media?.media
  if (!media) return null
  if (media.oneofKind === "photo") {
    const photo = media.photo.photo
    const bestSize = photo ? bestPhotoSize(photo) : { cdnUrl: null, width: null, height: null, sizeBytes: null }
    return {
      kind: "photo",
      id: photo?.id?.toString?.() ?? null,
      url: bestSize.cdnUrl,
      sizeBytes: bestSize.sizeBytes,
      width: bestSize.width,
      height: bestSize.height,
    }
  }
  if (media.oneofKind === "video") {
    const video = media.video.video
    return {
      kind: "video",
      id: video?.id?.toString?.() ?? null,
      url: video?.cdnUrl ?? null,
      sizeBytes: video?.size ?? null,
      width: video?.w ?? null,
      height: video?.h ?? null,
      durationSeconds: video?.duration ?? null,
    }
  }
  if (media.oneofKind === "document") {
    const document = media.document.document
    return {
      kind: "document",
      id: document?.id?.toString?.() ?? null,
      url: document?.cdnUrl ?? null,
      fileName: document?.fileName ?? null,
      mimeType: document?.mimeType ?? null,
      sizeBytes: document?.size ?? null,
    }
  }
  if (media.oneofKind === "voice") {
    const voice = media.voice.voice
    return {
      kind: "voice",
      id: voice?.id?.toString?.() ?? null,
      url: voice?.cdnUrl ?? null,
      mimeType: voice?.mimeType ?? null,
      sizeBytes: voice?.size ?? null,
      durationSeconds: voice?.duration ?? null,
    }
  }
  return {
    kind: "nudge",
    id: null,
    url: null,
  }
}

function previewMediaTypeLabel(mediaType: UrlPreview["mediaType"]): string | null {
  switch (mediaType) {
    case 1:
      return "article"
    case 2:
      return "image"
    case 3:
      return "video"
    case 4:
      return "document"
    case 5:
      return "embed"
    default:
      return null
  }
}

function previewMediaSummary(preview: UrlPreview):
  | {
      kind: "photo" | "video" | "document" | "external_video" | "embed"
      url: string | null
      width?: number | null
      height?: number | null
      durationSeconds?: number | null
      mimeType?: string | null
    }
  | null {
  const media = preview.media?.media
  if (!media || !media.oneofKind) {
    if (!preview.photo) return null
    const best = bestPhotoSize(preview.photo)
    return {
      kind: "photo",
      url: best.cdnUrl,
      width: best.width,
      height: best.height,
    }
  }
  if (media.oneofKind === "photo") {
    const best = bestPhotoSize(media.photo)
    return {
      kind: "photo",
      url: best.cdnUrl,
      width: best.width,
      height: best.height,
    }
  }
  if (media.oneofKind === "video") {
    return {
      kind: "video",
      url: media.video.cdnUrl ?? null,
      width: media.video.w ?? null,
      height: media.video.h ?? null,
      durationSeconds: media.video.duration ?? null,
    }
  }
  if (media.oneofKind === "document") {
    return {
      kind: "document",
      url: media.document.cdnUrl ?? null,
      mimeType: media.document.mimeType ?? null,
    }
  }
  if (media.oneofKind === "externalVideo") {
    return {
      kind: "external_video",
      url: media.externalVideo.url,
      width: media.externalVideo.w ?? null,
      height: media.externalVideo.h ?? null,
      durationSeconds: media.externalVideo.duration ?? null,
      mimeType: media.externalVideo.mimeType ?? null,
    }
  }
  if (media.oneofKind === "embed") {
    return {
      kind: "embed",
      url: media.embed.url,
      width: media.embed.w ?? null,
      height: media.embed.h ?? null,
      durationSeconds: media.embed.duration ?? null,
    }
  }
  return null
}

function externalTaskStatusLabel(status: number): string {
  switch (status) {
    case 1:
      return "backlog"
    case 2:
      return "todo"
    case 3:
      return "in_progress"
    case 4:
      return "done"
    case 5:
      return "cancelled"
    default:
      return "unspecified"
  }
}

function messageUrlPreviews(message: Message) {
  const previews = []
  for (const attachment of message.attachments?.attachments ?? []) {
    if (attachment.attachment.oneofKind !== "urlPreview") continue
    const preview = attachment.attachment.urlPreview
    previews.push({
      attachmentId: attachment.id.toString(),
      id: preview.id.toString(),
      url: preview.url ?? null,
      displayUrl: preview.displayUrl ?? null,
      siteName: preview.siteName ?? null,
      title: preview.title ?? null,
      description: preview.description ?? null,
      provider: preview.provider ?? null,
      author: preview.author ?? null,
      mediaType: previewMediaTypeLabel(preview.mediaType),
      durationSeconds: preview.duration != null ? Number(preview.duration) : null,
      media: previewMediaSummary(preview),
    })
  }
  return previews
}

function messageExternalTasks(message: Message) {
  const tasks = []
  for (const attachment of message.attachments?.attachments ?? []) {
    if (attachment.attachment.oneofKind !== "externalTask") continue
    const task = attachment.attachment.externalTask
    tasks.push({
      attachmentId: attachment.id.toString(),
      id: task.id.toString(),
      taskId: task.taskId,
      application: task.application,
      title: task.title,
      status: externalTaskStatusLabel(task.status),
      assignedUserId: task.assignedUserId.toString(),
      url: task.url,
      number: task.number,
      date: task.date.toString(),
    })
  }
  return tasks
}

function messagePayload(message: Message) {
  const snippet = snippetOf(message.message)
  const media = messageMediaSummary(message)
  const links = extractMessageUrls(message)
  return {
    id: message.id.toString(),
    uri: messageUri(message.chatId, message.id),
    text: message.message ?? "",
    ...(snippet ? { snippet } : {}),
    out: message.out === true,
    chatId: message.chatId.toString(),
    fromId: message.fromId?.toString?.() ?? null,
    date: message.date?.toString?.() ?? null,
    replyToMsgId: message.replyToMsgId?.toString() ?? null,
    editDate: message.editDate?.toString?.() ?? null,
    groupedId: message.groupedId?.toString?.() ?? null,
    ...(message.mentioned != null ? { mentioned: message.mentioned } : {}),
    ...(message.isSticker != null ? { isSticker: message.isSticker } : {}),
    links,
    media,
    urlPreviews: messageUrlPreviews(message),
    externalTasks: messageExternalTasks(message),
  }
}

function chatMetadata(chat: InlineEligibleChat): {
  chatId: string
  uri: string
  title: string
  kind: "dm" | "home_thread" | "space_chat"
  space: { id: string | null; name: string | null } | null
  peer: { userId: string | null; displayName: string | null; username: string | null } | null
  chatTitle: string
  archived: boolean
  pinned: boolean
  unreadCount: number
  readMaxId: string | null
  lastMessageId: string | null
  lastMessageDate: string | null
} {
  const peer =
    chat.peerUserId != null || chat.peerDisplayName != null || chat.peerUsername != null
      ? {
          userId: chat.peerUserId?.toString() ?? null,
          displayName: chat.peerDisplayName ?? null,
          username: chat.peerUsername ?? null,
        }
      : null
  const space =
    chat.spaceId != null || chat.spaceName != null
      ? {
          id: chat.spaceId?.toString() ?? null,
          name: chat.spaceName ?? null,
        }
      : null

  return {
    chatId: chat.chatId.toString(),
    uri: chatUri(chat.chatId),
    title: sourceTitle(chat.title, chat.chatId),
    kind: chat.kind,
    space,
    peer,
    chatTitle: chat.chatTitle,
    archived: chat.archived,
    pinned: chat.pinned,
    unreadCount: chat.unreadCount,
    readMaxId: chat.readMaxId?.toString() ?? null,
    lastMessageId: chat.lastMessageId?.toString() ?? null,
    lastMessageDate: chat.lastMessageDate?.toString() ?? null,
  }
}

function conversationListItem(
  chat: InlineEligibleChat,
  rank: number,
  match?: {
    score: number
    reasons: string[]
  },
) {
  return {
    rank,
    ...chatMetadata(chat),
    ...(match
      ? {
          match: {
            score: match.score,
            reasons: match.reasons,
          },
        }
    : {}),
  }
}

function compareRecentChats(left: InlineEligibleChat, right: InlineEligibleChat): number {
  const leftDate = left.lastMessageDate ?? 0n
  const rightDate = right.lastMessageDate ?? 0n
  if (leftDate !== rightDate) return leftDate > rightDate ? -1 : 1
  if (left.chatId === right.chatId) return 0
  return left.chatId > right.chatId ? -1 : 1
}

function sortedConversations<T extends InlineEligibleChat>(items: T[], sort: ConversationSort): T[] {
  if (sort === "relevance") return items
  const copy = [...items]
  if (sort === "recent") return copy.sort(compareRecentChats)
  return copy.sort((left, right) => {
    if (left.unreadCount !== right.unreadCount) return right.unreadCount - left.unreadCount
    return compareRecentChats(left, right)
  })
}

function spacePayload(space: InlineSpaceSummary) {
  return {
    id: space.id.toString(),
    name: space.name,
    creator: space.creator,
    date: space.date?.toString() ?? null,
    isPublic: space.isPublic,
    chatCount: space.chatCount,
    unreadCount: space.unreadCount,
    lastMessageDate: space.lastMessageDate?.toString() ?? null,
  }
}

function personPayload(person: InlinePersonSummary, match?: { score: number; reasons: string[] }) {
  return {
    userId: person.userId.toString(),
    uri: userUri(person.userId),
    displayName: person.displayName,
    username: person.username,
    firstName: person.firstName,
    lastName: person.lastName,
    dmChatId: person.dmChatId?.toString() ?? null,
    spaces: person.spaceIds.map((spaceId, index) => ({
      id: spaceId.toString(),
      name: person.spaceNames[index] ?? null,
    })),
    ...(match
      ? {
          match: {
            score: match.score,
            reasons: match.reasons,
          },
        }
      : {}),
  }
}

function personCandidatePayload(person: InlinePersonCandidate) {
  return personPayload(person, {
    score: person.score,
    reasons: person.matchReasons,
  })
}

function conversationDetailsPayload(details: InlineConversationDetails) {
  return {
    chat: chatMetadata(details.chat),
    details: {
      description: details.description,
      emoji: details.emoji,
      isPublic: details.isPublic,
      date: details.date?.toString() ?? null,
      createdBy: details.createdBy?.toString() ?? null,
      parentChatId: details.parentChatId?.toString() ?? null,
      parentMessageId: details.parentMessageId?.toString() ?? null,
      number: details.number,
      pinnedMessageIds: details.pinnedMessageIds.map((id) => id.toString()),
      groupParticipantCount: details.groupParticipantCount,
    },
    participants: details.participants.map((person) => personPayload(person)),
  }
}

function directFilePayload(message: Message) {
  const media = messageMediaSummary(message)
  if (!media || media.kind === "nudge") return null
  return {
    source: "message_media" as const,
    messageId: message.id.toString(),
    kind: media.kind,
    id: media.id,
    url: media.url,
    fileName: media.kind === "document" ? media.fileName ?? null : null,
    mimeType: media.kind === "document" || media.kind === "voice" ? media.mimeType ?? null : null,
    sizeBytes: media.sizeBytes ?? null,
    width: media.kind === "photo" || media.kind === "video" ? media.width ?? null : null,
    height: media.kind === "photo" || media.kind === "video" ? media.height ?? null : null,
    durationSeconds: media.kind === "video" || media.kind === "voice" ? media.durationSeconds ?? null : null,
    title: null,
    pageUrl: null,
  }
}

function messageFilePayloads(message: Message, includeUrlPreviews: boolean) {
  const files = []
  const direct = directFilePayload(message)
  if (direct) files.push(direct)

  if (includeUrlPreviews) {
    for (const preview of messageUrlPreviews(message)) {
      const media = preview.media
      if (!media) continue
      files.push({
        source: "url_preview_media" as const,
        messageId: message.id.toString(),
        attachmentId: preview.attachmentId,
        kind: media.kind,
        id: null,
        url: media.url,
        fileName: null,
        mimeType: media.mimeType ?? null,
        sizeBytes: null,
        width: media.width ?? null,
        height: media.height ?? null,
        durationSeconds: media.durationSeconds ?? null,
        title: preview.title,
        pageUrl: preview.url,
      })
    }
  }

  return files
}

const chatMetadataOutputSchema = z.object({
  chatId: z.string(),
  uri: z.string(),
  title: z.string(),
  kind: z.enum(["dm", "home_thread", "space_chat"]),
  space: z
    .object({
      id: z.string().nullable(),
      name: z.string().nullable(),
    })
    .nullable(),
  peer: z
    .object({
      userId: z.string().nullable(),
      displayName: z.string().nullable(),
      username: z.string().nullable(),
    })
    .nullable(),
  chatTitle: z.string(),
  archived: z.boolean(),
  pinned: z.boolean(),
  unreadCount: z.number(),
  readMaxId: z.string().nullable(),
  lastMessageId: z.string().nullable(),
  lastMessageDate: z.string().nullable(),
})

const conversationListItemOutputSchema = chatMetadataOutputSchema.extend({
  rank: z.number(),
  match: z
    .object({
      score: z.number(),
      reasons: z.array(z.string()),
    })
    .optional(),
})

const spaceOutputSchema = z.object({
  id: z.string(),
  name: z.string(),
  creator: z.boolean(),
  date: z.string().nullable(),
  isPublic: z.boolean().nullable(),
  chatCount: z.number(),
  unreadCount: z.number(),
  lastMessageDate: z.string().nullable(),
})

const spacesListOutputSchema = z.object({
  query: z.string().nullable(),
  items: z.array(spaceOutputSchema),
})

const personOutputSchema = z.object({
  userId: z.string(),
  uri: z.string(),
  displayName: z.string(),
  username: z.string().nullable(),
  firstName: z.string().nullable(),
  lastName: z.string().nullable(),
  dmChatId: z.string().nullable(),
  spaces: z.array(
    z.object({
      id: z.string(),
      name: z.string().nullable(),
    }),
  ),
  match: z
    .object({
      score: z.number(),
      reasons: z.array(z.string()),
    })
    .optional(),
})

const peopleSearchOutputSchema = z.object({
  query: z.string().nullable(),
  bestMatch: personOutputSchema.nullable(),
  items: z.array(personOutputSchema),
})

const messageMediaOutputSchema = z
  .union([
    z.object({
      kind: z.literal("photo"),
      id: z.string().nullable(),
      url: z.string().nullable(),
      sizeBytes: z.number().nullable().optional(),
      width: z.number().nullable().optional(),
      height: z.number().nullable().optional(),
    }),
    z.object({
      kind: z.literal("video"),
      id: z.string().nullable(),
      url: z.string().nullable(),
      sizeBytes: z.number().nullable().optional(),
      width: z.number().nullable().optional(),
      height: z.number().nullable().optional(),
      durationSeconds: z.number().nullable().optional(),
    }),
    z.object({
      kind: z.literal("document"),
      id: z.string().nullable(),
      url: z.string().nullable(),
      fileName: z.string().nullable().optional(),
      mimeType: z.string().nullable().optional(),
      sizeBytes: z.number().nullable().optional(),
    }),
    z.object({
      kind: z.literal("voice"),
      id: z.string().nullable(),
      url: z.string().nullable(),
      mimeType: z.string().nullable().optional(),
      sizeBytes: z.number().nullable().optional(),
      durationSeconds: z.number().nullable().optional(),
    }),
    z.object({
      kind: z.literal("nudge"),
      id: z.string().nullable(),
      url: z.string().nullable(),
    }),
  ])
  .nullable()

const urlPreviewMediaOutputSchema = z
  .object({
    kind: z.enum(["photo", "video", "document", "external_video", "embed"]),
    url: z.string().nullable(),
    width: z.number().nullable().optional(),
    height: z.number().nullable().optional(),
    durationSeconds: z.number().nullable().optional(),
    mimeType: z.string().nullable().optional(),
  })
  .nullable()

const urlPreviewOutputSchema = z.object({
  attachmentId: z.string(),
  id: z.string(),
  url: z.string().nullable(),
  displayUrl: z.string().nullable(),
  siteName: z.string().nullable(),
  title: z.string().nullable(),
  description: z.string().nullable(),
  provider: z.string().nullable(),
  author: z.string().nullable(),
  mediaType: z.enum(["article", "image", "video", "document", "embed"]).nullable(),
  durationSeconds: z.number().nullable(),
  media: urlPreviewMediaOutputSchema,
})

const externalTaskOutputSchema = z.object({
  attachmentId: z.string(),
  id: z.string(),
  taskId: z.string(),
  application: z.string(),
  title: z.string(),
  status: z.enum(["unspecified", "backlog", "todo", "in_progress", "done", "cancelled"]),
  assignedUserId: z.string(),
  url: z.string(),
  number: z.string(),
  date: z.string(),
})

const messageOutputSchema = z.object({
  id: z.string(),
  uri: z.string(),
  text: z.string(),
  snippet: z.string().optional(),
  out: z.boolean(),
  chatId: z.string(),
  fromId: z.string().nullable(),
  date: z.string().nullable(),
  replyToMsgId: z.string().nullable(),
  editDate: z.string().nullable(),
  groupedId: z.string().nullable(),
  mentioned: z.boolean().optional(),
  isSticker: z.boolean().optional(),
  links: z.array(z.string()),
  media: messageMediaOutputSchema,
  urlPreviews: z.array(urlPreviewOutputSchema),
  externalTasks: z.array(externalTaskOutputSchema),
})

const contentFilterOutputSchema = z.enum(["all", "links", "media", "photos", "videos", "documents", "files"])

const sendMetadataOutputSchema = z.object({
  sendMode: z.enum(["normal", "silent"]),
  replyToMsgId: z.string().optional(),
})

const accountContextOutputSchema = z.object({
  user: z.object({
    id: z.string(),
  }),
  session: z.object({
    clientId: z.string(),
    scopes: z.array(z.string()),
    expiresAt: z.number().nullable(),
  }),
  allowed: z.object({
    spaceIds: z.array(z.string()),
    allowDms: z.boolean(),
    allowHomeThreads: z.boolean(),
  }),
  hints: z.array(z.string()),
})

const conversationsListOutputSchema = z.object({
  query: z.string().nullable(),
  sort: z.enum(["relevance", "recent", "unread"]),
  bestMatch: conversationListItemOutputSchema.nullable(),
  unreadOnly: z.boolean(),
  items: z.array(conversationListItemOutputSchema),
})

const conversationGetOutputSchema = z.object({
  chat: chatMetadataOutputSchema,
  details: z.object({
    description: z.string().nullable(),
    emoji: z.string().nullable(),
    isPublic: z.boolean().nullable(),
    date: z.string().nullable(),
    createdBy: z.string().nullable(),
    parentChatId: z.string().nullable(),
    parentMessageId: z.string().nullable(),
    number: z.number().nullable(),
    pinnedMessageIds: z.array(z.string()),
    groupParticipantCount: z.number(),
  }),
  participants: z.array(personOutputSchema),
})

const conversationCreatedOutputSchema = z.object({
  chat: chatMetadataOutputSchema,
})

const fileUploadOutputSchema = z.object({
  ok: z.boolean(),
  source: z.enum(["base64", "url"]),
  sourceRef: z.string().nullable(),
  sizeBytes: z.number(),
  upload: z.object({
    fileUniqueId: z.string(),
    media: z.object({
      kind: z.enum(["photo", "video", "document"]),
      id: z.string(),
    }),
    uploadKind: z.enum(["photo", "video", "document"]),
    fileName: z.string(),
    contentType: z.string().nullable(),
  }),
})

const sendMessageOutputSchema = z.object({
  ok: z.boolean(),
  chatId: z.string().optional(),
  userId: z.string().optional(),
  text: z.string().optional(),
  messageId: z.string().nullable(),
  metadata: sendMetadataOutputSchema,
})

const sendMediaMessageOutputSchema = z.object({
  ok: z.boolean(),
  chatId: z.string().optional(),
  userId: z.string().optional(),
  media: z.object({
    kind: z.enum(["photo", "video", "document"]),
    id: z.string(),
  }),
  text: z.string().optional(),
  messageId: z.string().nullable(),
  metadata: sendMetadataOutputSchema,
})

const sendBatchResultOutputSchema = z.object({
  index: z.number(),
  type: z.enum(["text", "media"]),
  status: z.enum(["sent", "failed"]),
  messageId: z.string().nullable().optional(),
  media: z
    .object({
      kind: z.enum(["photo", "video", "document"]),
      id: z.string(),
    })
    .optional(),
  text: z.string().optional(),
  metadata: sendMetadataOutputSchema.optional(),
  error: z.string().optional(),
})

const sendBatchOutputSchema = z.object({
  ok: z.boolean(),
  chatId: z.string().optional(),
  userId: z.string().optional(),
  stopOnError: z.boolean(),
  total: z.number(),
  sentCount: z.number(),
  failedCount: z.number(),
  results: z.array(sendBatchResultOutputSchema),
})

const messagesListOutputSchema = z.object({
  chat: chatMetadataOutputSchema,
  nextOffsetId: z.string().nullable(),
  since: z.string().nullable(),
  until: z.string().nullable(),
  content: contentFilterOutputSchema,
  messages: z.array(messageOutputSchema),
})

const messagesContextOutputSchema = z.object({
  chat: chatMetadataOutputSchema,
  anchorMessageId: z.string().nullable(),
  before: z.number(),
  after: z.number(),
  includeAnchor: z.boolean(),
  content: contentFilterOutputSchema,
  messages: z.array(messageOutputSchema),
})

const messagesSearchOutputSchema = z.object({
  query: z.string().nullable(),
  content: contentFilterOutputSchema,
  since: z.string().nullable(),
  until: z.string().nullable(),
  chat: chatMetadataOutputSchema,
  messages: z.array(messageOutputSchema),
})

const messagesUnreadOutputSchema = z.object({
  scannedChats: z.number(),
  since: z.string().nullable(),
  until: z.string().nullable(),
  content: contentFilterOutputSchema,
  items: z.array(
    z.object({
      chat: chatMetadataOutputSchema,
      message: messageOutputSchema,
    }),
  ),
})

const fileItemOutputSchema = z.object({
  source: z.enum(["message_media", "url_preview_media"]),
  messageId: z.string(),
  attachmentId: z.string().optional(),
  kind: z.enum(["photo", "video", "document", "voice", "external_video", "embed"]),
  id: z.string().nullable(),
  url: z.string().nullable(),
  fileName: z.string().nullable(),
  mimeType: z.string().nullable(),
  sizeBytes: z.number().nullable(),
  width: z.number().nullable(),
  height: z.number().nullable(),
  durationSeconds: z.number().nullable(),
  title: z.string().nullable(),
  pageUrl: z.string().nullable(),
})

const filesGetOutputSchema = z.object({
  chat: chatMetadataOutputSchema,
  source: z.enum(["messages", "recent"]),
  messageIds: z.array(z.string()).nullable(),
  includeUrlPreviews: z.boolean(),
  items: z.array(
    z.object({
      message: messageOutputSchema,
      files: z.array(fileItemOutputSchema),
    }),
  ),
})

export function createInlineMcpServer(params: {
  grant: McpGrant
  inline: InlineApi
  resourceMetadataUrl?: string
}): McpServer {
  const resourceMetadataUrl = params.resourceMetadataUrl ?? DEFAULT_RESOURCE_METADATA_URL
  const server = new McpServer(
    {
      name: "inline",
      version: "0.1.0",
      title: "Inline",
      description: "Scoped access to Inline work chats for thread-first agents.",
      websiteUrl: "https://inline.chat",
    },
    {
      capabilities: {
        tools: { listChanged: false },
      },
      instructions: INLINE_MCP_INSTRUCTIONS,
    },
  )

  registerInlineTool(
    server,
    resourceMetadataUrl,
    "account.me",
    {
      title: "Get Inline MCP Account Context",
      description:
        "Use this tool when you need to inspect the current Inline MCP authorization, granted scopes, and allowed chat contexts before choosing read/write tools.",
      inputSchema: {},
      outputSchema: accountContextOutputSchema,
      annotations: {
        title: "Account Context",
        readOnlyHint: true,
        openWorldHint: false,
      },
      _meta: toolMeta([], "Checking Inline MCP context...", "Inline MCP context checked"),
    },
    async (_args: {}, extra: { authInfo?: AuthInfo }) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      const payload = {
        user: {
          id: params.grant.inlineUserId.toString(),
        },
        session: {
          clientId: params.grant.clientId,
          scopes,
          expiresAt: auth?.expiresAt ?? null,
        },
        allowed: {
          spaceIds: params.grant.spaceIds.map((spaceId) => spaceId.toString()),
          allowDms: params.grant.allowDms,
          allowHomeThreads: params.grant.allowHomeThreads,
        },
        hints: [
          "Use people.search, spaces.list, and conversations.list to resolve users, spaces, DMs, thread titles, or chat IDs before reading or sending.",
          "Use messages.context around search or unread results when a single message needs surrounding context.",
          "Message reads require messages:read; space listing and people search require spaces:read; sends and uploads require messages:write.",
        ],
      }
      return {
        structuredContent: payload,
        content: [jsonText(payload)],
      }
    },
  )

  registerInlineTool(
    server,
    resourceMetadataUrl,
    "spaces.list",
    {
      title: "List Inline Spaces",
      description:
        "Use this tool to list the spaces available to this MCP grant, including chat and unread counts. Use it before creating a space thread or narrowing conversation searches by team/workspace.",
      inputSchema: {
        query: z.string().min(1).optional().describe("Optional space name or space ID filter"),
        limit: z.number().int().min(1).max(50).default(20).describe("Maximum spaces to return"),
      },
      outputSchema: spacesListOutputSchema,
      annotations: {
        title: "List Spaces",
        readOnlyHint: true,
        openWorldHint: false,
      },
      _meta: toolMeta(["spaces:read"], "Listing Inline spaces...", "Spaces listed"),
    },
    async ({ query, limit }: { query?: string; limit?: number }, extra: { authInfo?: AuthInfo }) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "spaces:read")

      const safeQuery = query?.trim()
      const spaces = await params.inline.listSpaces({ ...(safeQuery ? { query: safeQuery } : {}), limit: limit ?? 20 })
      const payload = {
        query: safeQuery || null,
        items: spaces.map(spacePayload),
      }
      return {
        structuredContent: payload,
        content: [jsonText(payload)],
      }
    },
  )

  registerInlineTool(
    server,
    resourceMetadataUrl,
    "people.search",
    {
      title: "Search Inline People",
      description:
        "Use this tool to resolve a person by name, @username, or user ID across allowed DMs and spaces. It returns userId for DMs and participant selection without exposing phone or email.",
      inputSchema: {
        query: z.string().min(1).optional().describe("Name, @username, or user ID. Omit to list known people in allowed contexts."),
        limit: z.number().int().min(1).max(50).default(20).describe("Maximum people to return"),
      },
      outputSchema: peopleSearchOutputSchema,
      annotations: {
        title: "Search People",
        readOnlyHint: true,
        openWorldHint: false,
      },
      _meta: toolMeta(["messages:read", "spaces:read"], "Searching Inline people...", "People searched"),
    },
    async ({ query, limit }: { query?: string; limit?: number }, extra: { authInfo?: AuthInfo }) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:read")
      requireScope(scopes, "spaces:read")

      const safeQuery = query?.trim()
      const result = await params.inline.searchPeople({ ...(safeQuery ? { query: safeQuery } : {}), limit: limit ?? 20 })
      const items = result.items.map(personCandidatePayload)
      const payload = {
        query: result.query,
        bestMatch: result.bestMatch ? personCandidatePayload(result.bestMatch) : null,
        items,
      }
      return {
        structuredContent: payload,
        content: [jsonText(payload)],
      }
    },
  )

  registerInlineTool(
    server,
    resourceMetadataUrl,
    "conversations.list",
    {
      title: "List Inline Conversations",
      description:
        "Use this tool to find the chatId for a person, DM, thread, or space chat before listing messages or sending. Query can be a contact name, @username, chat title, or chat ID; omit query for recent approved conversations.",
      inputSchema: {
        query: z.string().min(1).optional().describe("Optional contact name, chat title, or chat ID"),
        limit: z.number().int().min(1).max(50).default(20).describe("Maximum conversations to return"),
        unreadOnly: z.boolean().default(false).describe("Only include conversations with unread messages"),
        sort: z
          .enum(["relevance", "recent", "unread"])
          .optional()
          .describe("Sort mode. Defaults to `relevance` for queries and `recent` when listing without a query."),
      },
      outputSchema: conversationsListOutputSchema,
      annotations: {
        title: "List Conversations",
        readOnlyHint: true,
        openWorldHint: false,
      },
      _meta: toolMeta(["messages:read"], "Listing Inline conversations...", "Conversations listed"),
    },
    async (
      { query, limit, unreadOnly, sort }: { query?: string; limit?: number; unreadOnly?: boolean; sort?: ConversationSort },
      extra: { authInfo?: AuthInfo },
    ) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:read")

      const safeLimit = Math.max(1, Math.min(50, limit ?? 20))
      const safeQuery = query?.trim()
      const onlyUnread = unreadOnly === true
      const safeSort = parseConversationSort(sort, !!safeQuery)

      if (!safeQuery) {
        const chats = await params.inline.getEligibleChats()
        const filtered = onlyUnread ? chats.filter((chat) => chat.unreadCount > 0) : chats
        const items = sortedConversations(filtered, safeSort)
          .slice(0, safeLimit)
          .map((chat, index) => conversationListItem(chat, index + 1))
        const payload = {
          query: null,
          sort: safeSort,
          bestMatch: null,
          unreadOnly: onlyUnread,
          items,
        }
        return {
          structuredContent: payload,
          content: [jsonText(payload)],
        }
      }

      const resolved = await params.inline.resolveConversation(safeQuery, safeLimit)
      const filtered = onlyUnread ? resolved.candidates.filter((candidate) => candidate.unreadCount > 0) : resolved.candidates
      const sorted = sortedConversations(filtered, safeSort)
      const items = sorted.map((candidate: InlineConversationCandidate, index: number) =>
        conversationListItem(candidate, index + 1, {
          score: candidate.score,
          reasons: candidate.matchReasons,
        }),
      )
      const bestMatchChatId = onlyUnread
        ? resolved.selected?.unreadCount
          ? resolved.selected.chatId.toString()
          : null
        : resolved.selected?.chatId.toString() ?? null
      const bestMatch = bestMatchChatId ? items.find((item) => item.chatId === bestMatchChatId) ?? null : null
      const payload = {
        query: resolved.query,
        sort: safeSort,
        bestMatch,
        unreadOnly: onlyUnread,
        items,
      }
      return {
        structuredContent: payload,
        content: [jsonText(payload)],
      }
    },
  )

  registerInlineTool(
    server,
    resourceMetadataUrl,
    "conversations.get",
    {
      title: "Get Inline Conversation",
      description:
        "Use this tool after resolving a chatId or DM userId to inspect the conversation metadata, participants, pinned message IDs, and parent/thread details before reading or sending.",
      inputSchema: {
        chatId: z.string().min(1).optional().describe("Inline chat ID"),
        userId: z.string().min(1).optional().describe("Inline user ID (DM target)"),
      },
      outputSchema: conversationGetOutputSchema,
      annotations: {
        title: "Get Conversation",
        readOnlyHint: true,
        openWorldHint: false,
      },
      _meta: toolMeta(["messages:read"], "Getting conversation...", "Conversation loaded"),
    },
    async ({ chatId, userId }: { chatId?: string; userId?: string }, extra: { authInfo?: AuthInfo }) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:read")

      const target = parseTarget({ chatId, userId }, "conversations.get")
      const details = await params.inline.getConversation(target)
      const payload = conversationDetailsPayload(details)
      return {
        structuredContent: payload,
        content: [jsonText(payload)],
      }
    },
  )

  registerInlineTool(
    server,
    resourceMetadataUrl,
    "conversations.create",
    {
      title: "Create Inline Conversation",
      description:
        "Use this tool to create a new Inline thread/chat in an allowed space or home threads. After creation, use messages.send or messages.send_batch with the returned chat.chatId.",
      inputSchema: {
        title: z.string().min(1).max(200).describe("Conversation title"),
        spaceId: z.string().min(1).optional().describe("Parent space ID for a thread"),
        description: z.string().max(1000).optional().describe("Optional description"),
        emoji: z.string().max(16).optional().describe("Optional emoji icon"),
        isPublic: z.boolean().default(false).describe("Whether the conversation is public"),
        participantUserIds: z.array(z.string().min(1)).max(50).default([]).describe("Participant user IDs (for private chats)"),
      },
      outputSchema: conversationCreatedOutputSchema,
      annotations: {
        title: "Create Conversation",
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false,
      },
      _meta: toolMeta(["messages:write"], "Creating conversation...", "Conversation created"),
    },
    async (
      args: {
        title: string
        spaceId?: string
        description?: string
        emoji?: string
        isPublic?: boolean
        participantUserIds?: string[]
      },
      extra: { authInfo?: AuthInfo },
    ) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:write")

      const created = await params.inline.createChat({
        title: args.title,
        ...(args.spaceId ? { spaceId: parseChatId(args.spaceId) } : {}),
        ...(args.description ? { description: args.description } : {}),
        ...(args.emoji ? { emoji: args.emoji } : {}),
        ...(args.isPublic != null ? { isPublic: args.isPublic } : {}),
        participantUserIds: coerceBigIntArray(args.participantUserIds, "participantUserIds"),
      })

      const payload = {
        chat: chatMetadata(created),
      }
      return {
        structuredContent: payload,
        content: [jsonText(payload)],
      }
    },
  )

  registerInlineTool(
    server,
    resourceMetadataUrl,
    "files.upload",
    {
      title: "Upload File For Inline Media",
      description:
        "Use this tool to upload a local base64 payload or public HTTPS URL before sending media. It returns an Inline media kind/id pair for messages.send_media or messages.send_batch.",
      inputSchema: {
        kind: z.enum(["auto", "photo", "video", "document"]).default("auto").describe("Upload kind (`auto` infers photo/video/document)"),
        base64: z.string().min(1).optional().describe("Base64 payload or data URL"),
        url: z.string().url().optional().describe("HTTPS URL to download and upload"),
        fileName: z.string().max(255).optional().describe("Optional file name override"),
        contentType: z.string().max(255).optional().describe("Optional content type override"),
        width: z.number().int().positive().optional().describe("Video width (video uploads only)"),
        height: z.number().int().positive().optional().describe("Video height (video uploads only)"),
        duration: z.number().int().positive().optional().describe("Video duration in seconds (video uploads only)"),
      },
      outputSchema: fileUploadOutputSchema,
      annotations: {
        title: "Upload File",
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true,
      },
      _meta: toolMeta(["messages:write"], "Uploading file...", "File uploaded"),
    },
    async (
      {
        kind,
        base64,
        url,
        fileName,
        contentType,
        width,
        height,
        duration,
      }: {
        kind?: RequestedUploadKind
        base64?: string
        url?: string
        fileName?: string
        contentType?: string
        width?: number
        height?: number
        duration?: number
      },
      extra: { authInfo?: AuthInfo },
    ) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:write")

      const source = await resolveUploadSource({ base64, url })
      const requestedKind = parseUploadKind(kind)
      const safeContentType = parseContentTypeArg(contentType) ?? source.inferredContentType
      const chosenKind = chooseUploadType({
        requestedKind,
        mime: safeContentType,
        fileName: fileName ?? source.inferredFileName,
      })
      const safeFileName = ensureUploadFileName(fileName ?? source.inferredFileName, chosenKind, safeContentType)
      const safeWidth = parsePositiveInt(width, "width")
      const safeHeight = parsePositiveInt(height, "height")
      const safeDuration = parsePositiveInt(duration, "duration")

      const uploaded = await params.inline.uploadFile({
        type: chosenKind,
        file: source.bytes,
        fileName: safeFileName,
        ...(safeContentType ? { contentType: safeContentType } : {}),
        ...(chosenKind === "video" && safeWidth != null ? { width: safeWidth } : {}),
        ...(chosenKind === "video" && safeHeight != null ? { height: safeHeight } : {}),
        ...(chosenKind === "video" && safeDuration != null ? { duration: safeDuration } : {}),
      })

      const payload = {
        ok: true,
        source: source.sourceKind,
        sourceRef: source.sourceRef,
        sizeBytes: source.bytes.byteLength,
        upload: {
          fileUniqueId: uploaded.fileUniqueId,
          media: {
            kind: uploaded.media.kind,
            id: uploaded.media.id.toString(),
          },
          uploadKind: chosenKind,
          fileName: safeFileName,
          contentType: safeContentType ?? null,
        },
      }

      return {
        structuredContent: payload,
        content: [jsonText(payload)],
      }
    },
  )

  registerInlineTool(
    server,
    resourceMetadataUrl,
    "files.get",
    {
      title: "Get Inline Message Files",
      description:
        "Use this tool to extract file/media metadata and URLs from specific message IDs, or from recent messages in one chat/DM when message IDs are not known.",
      inputSchema: {
        chatId: z.string().min(1).optional().describe("Inline chat ID"),
        userId: z.string().min(1).optional().describe("Inline user ID (DM target)"),
        messageId: z.string().min(1).optional().describe("Single message ID to inspect"),
        messageIds: z.array(z.string().min(1)).max(20).optional().describe("Message IDs to inspect"),
        limit: z.number().int().min(1).max(50).default(20).describe("Recent messages to scan when no message IDs are provided"),
        includeUrlPreviews: z.boolean().default(true).describe("Include media embedded in URL previews"),
      },
      outputSchema: filesGetOutputSchema,
      annotations: {
        title: "Get Files",
        readOnlyHint: true,
        openWorldHint: false,
      },
      _meta: toolMeta(["messages:read"], "Getting files...", "Files loaded"),
    },
    async (
      {
        chatId,
        userId,
        messageId,
        messageIds,
        limit,
        includeUrlPreviews,
      }: {
        chatId?: string
        userId?: string
        messageId?: string
        messageIds?: string[]
        limit?: number
        includeUrlPreviews?: boolean
      },
      extra: { authInfo?: AuthInfo },
    ) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:read")

      const target = parseTarget({ chatId, userId }, "files.get")
      const ids = [...(messageId ? [messageId] : []), ...(messageIds ?? [])].map((id) => parseInlineId(id, "messageId"))
      if (ids.length > 20) throw new Error("messageIds length must be at most 20")
      const includePreviews = includeUrlPreviews !== false
      const result =
        ids.length > 0
          ? await params.inline.getMessages({
              ...target,
              messageIds: ids,
            })
          : await params.inline.recentMessages({
              ...target,
              limit: limit ?? 20,
              content: "all",
            })

      const messages = result.messages
      const items = messages
        .map((message) => ({
          message: messagePayload(message),
          files: messageFilePayloads(message, includePreviews),
        }))
        .filter((item) => item.files.length > 0)
      const payload = {
        chat: chatMetadata(result.chat),
        source: ids.length > 0 ? ("messages" as const) : ("recent" as const),
        messageIds: ids.length > 0 ? ids.map((id) => id.toString()) : null,
        includeUrlPreviews: includePreviews,
        items,
      }
      return {
        structuredContent: payload,
        content: [jsonText(payload)],
      }
    },
  )

  registerInlineTool(
    server,
    resourceMetadataUrl,
    "messages.send_media",
    {
      title: "Send Inline Media Message",
      description:
        "Use this tool to send an uploaded photo, video, or document to one chat or DM. Call files.upload first unless you already have an Inline media ID.",
      inputSchema: {
        chatId: z.string().min(1).optional().describe("Inline chat ID"),
        userId: z.string().min(1).optional().describe("Inline user ID (DM target)"),
        mediaKind: z.enum(["photo", "video", "document"]).describe("Uploaded media kind"),
        mediaId: z.string().min(1).describe("Uploaded media ID"),
        text: z.string().max(8000).optional().describe("Optional caption text"),
        replyToMsgId: z.string().min(1).optional().describe("Reply-to message ID"),
        sendMode: z.enum(["normal", "silent"]).default("normal").describe("Message delivery mode"),
      },
      outputSchema: sendMediaMessageOutputSchema,
      annotations: {
        title: "Send Media Message",
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false,
      },
      _meta: toolMeta(["messages:write"], "Sending media message...", "Media message sent"),
    },
    async (
      {
        chatId,
        userId,
        mediaKind,
        mediaId,
        text,
        replyToMsgId,
        sendMode,
      }: {
        chatId?: string
        userId?: string
        mediaKind: InlineUploadedMediaKind
        mediaId: string
        text?: string
        replyToMsgId?: string
        sendMode?: "normal" | "silent"
      },
      extra: { authInfo?: AuthInfo },
    ) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:write")

      const target = parseTarget({ chatId, userId }, "messages.send_media")
      const safeSendMode: "normal" | "silent" = sendMode === "silent" ? "silent" : "normal"
      const caption = text?.trim()
      const parsedMediaId = parseInlineId(mediaId, "mediaId")
      const res = await params.inline.sendMediaMessage({
        ...target,
        media: {
          kind: mediaKind,
          id: parsedMediaId,
        },
        ...(caption ? { text: caption } : {}),
        ...(replyToMsgId ? { replyToMsgId: parseInlineId(replyToMsgId, "replyToMsgId") } : {}),
        sendMode: safeSendMode,
        parseMarkdown: true,
      })

      const payload = {
        ok: true,
        ...(chatId ? { chatId } : {}),
        ...(userId ? { userId } : {}),
        media: {
          kind: mediaKind,
          id: parsedMediaId.toString(),
        },
        ...(caption ? { text: caption } : {}),
        messageId: res.messageId?.toString() ?? null,
        metadata: {
          sendMode: safeSendMode,
          ...(replyToMsgId ? { replyToMsgId } : {}),
        },
      }
      return {
        structuredContent: payload,
        content: [jsonText(payload)],
      }
    },
  )

  registerInlineTool(
    server,
    resourceMetadataUrl,
    "messages.send_batch",
    {
      title: "Send Inline Message Batch",
      description:
        "Use this tool to send an ordered sequence of text and uploaded media items to one chat or DM. Prefer this over many separate sends when seeding a new thread or posting a multi-part update.",
      inputSchema: {
        chatId: z.string().min(1).optional().describe("Inline chat ID"),
        userId: z.string().min(1).optional().describe("Inline user ID (DM target)"),
        stopOnError: z.boolean().default(false).describe("Stop sending after the first item error"),
        items: z
          .array(
            z.discriminatedUnion("type", [
              z.object({
                type: z.literal("text"),
                text: z.string().min(1).max(8000),
                replyToMsgId: z.string().min(1).optional(),
                sendMode: z.enum(["normal", "silent"]).default("normal"),
              }),
              z.object({
                type: z.literal("media"),
                mediaKind: z.enum(["photo", "video", "document"]),
                mediaId: z.string().min(1),
                text: z.string().max(8000).optional(),
                replyToMsgId: z.string().min(1).optional(),
                sendMode: z.enum(["normal", "silent"]).default("normal"),
              }),
            ]),
          )
          .min(1)
          .max(100)
          .describe("Ordered list of message items"),
      },
      outputSchema: sendBatchOutputSchema,
      annotations: {
        title: "Send Message Batch",
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false,
      },
      _meta: toolMeta(["messages:write"], "Sending batch...", "Batch sent"),
    },
    async (
      {
        chatId,
        userId,
        stopOnError,
        items,
      }: {
        chatId?: string
        userId?: string
        stopOnError?: boolean
        items: SendBatchItem[]
      },
      extra: { authInfo?: AuthInfo },
    ) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:write")

      const target = parseTarget({ chatId, userId }, "messages.send_batch")
      const safeStopOnError = stopOnError === true
      const results: Array<Record<string, unknown>> = []
      let sentCount = 0
      let failedCount = 0

      for (let index = 0; index < items.length; index += 1) {
        const item = items[index]
        try {
          const safeSendMode: SendMode = item.sendMode === "silent" ? "silent" : "normal"
          if (item.type === "text") {
            const sent = await params.inline.sendMessage({
              ...target,
              text: item.text,
              ...(item.replyToMsgId ? { replyToMsgId: parseInlineId(item.replyToMsgId, "replyToMsgId") } : {}),
              sendMode: safeSendMode,
              parseMarkdown: true,
            })
            sentCount += 1
            results.push({
              index,
              type: "text",
              status: "sent",
              messageId: sent.messageId?.toString() ?? null,
              metadata: {
                sendMode: safeSendMode,
                ...(item.replyToMsgId ? { replyToMsgId: item.replyToMsgId } : {}),
              },
            })
            continue
          }

          const parsedMediaId = parseInlineId(item.mediaId, "mediaId")
          const caption = item.text?.trim()
          const sent = await params.inline.sendMediaMessage({
            ...target,
            media: {
              kind: item.mediaKind,
              id: parsedMediaId,
            },
            ...(caption ? { text: caption } : {}),
            ...(item.replyToMsgId ? { replyToMsgId: parseInlineId(item.replyToMsgId, "replyToMsgId") } : {}),
            sendMode: safeSendMode,
            parseMarkdown: true,
          })
          sentCount += 1
          results.push({
            index,
            type: "media",
            status: "sent",
            messageId: sent.messageId?.toString() ?? null,
            media: {
              kind: item.mediaKind,
              id: parsedMediaId.toString(),
            },
            ...(caption ? { text: caption } : {}),
            metadata: {
              sendMode: safeSendMode,
              ...(item.replyToMsgId ? { replyToMsgId: item.replyToMsgId } : {}),
            },
          })
        } catch (error) {
          failedCount += 1
          const message = error instanceof Error ? error.message : String(error)
          results.push({
            index,
            type: item.type,
            status: "failed",
            error: message,
          })
          if (safeStopOnError) break
        }
      }

      const payload = {
        ok: failedCount === 0,
        ...(chatId ? { chatId } : {}),
        ...(userId ? { userId } : {}),
        stopOnError: safeStopOnError,
        total: items.length,
        sentCount,
        failedCount,
        results,
      }

      return {
        structuredContent: payload,
        content: [jsonText(payload)],
      }
    },
  )

  registerInlineTool(
    server,
    resourceMetadataUrl,
    "messages.list",
    {
      title: "List Inline Messages",
      description:
        "Use this tool to read recent context from one resolved chatId or DM userId for summarization, answering questions, or preparing a reply. Supports time windows like today, yesterday, 2d ago, YYYY-MM-DD, or epoch seconds.",
      inputSchema: {
        chatId: z.string().min(1).optional().describe("Inline chat ID"),
        userId: z.string().min(1).optional().describe("Inline user ID (DM target)"),
        limit: z.number().int().min(1).max(50).default(20).describe("Maximum messages to return"),
        offsetId: z.string().min(1).optional().describe("Fetch messages older than this message ID"),
        since: z.string().min(1).optional().describe("Lower time bound (e.g. yesterday, 2d ago, 2026-02-20)"),
        until: z.string().min(1).optional().describe("Upper time bound"),
        content: z.enum(["all", "links", "media", "photos", "videos", "documents", "files"]).default("all").describe("Content type filter"),
      },
      outputSchema: messagesListOutputSchema,
      annotations: {
        title: "List Messages",
        readOnlyHint: true,
        openWorldHint: false,
      },
      _meta: toolMeta(["messages:read"], "Listing messages...", "Messages listed"),
    },
    async (
      {
        chatId,
        userId,
        limit,
        offsetId,
        since,
        until,
        content,
      }: {
        chatId?: string
        userId?: string
        limit?: number
        offsetId?: string
        since?: string
        until?: string
        content?: InlineMessageContentFilter
      },
      extra: { authInfo?: AuthInfo },
    ) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:read")

      const target = parseTarget({ chatId, userId }, "messages.list")
      const parsedOffsetId = offsetId ? parseChatId(offsetId) : undefined
      const parsedSince = parseTimeInput(since, "since")
      const parsedUntil = parseTimeInput(until, "until")
      const safeContent = parseContentFilter(content)
      const recent = await params.inline.recentMessages({
        ...target,
        limit: limit ?? 20,
        offsetId: parsedOffsetId,
        since: parsedSince,
        until: parsedUntil,
        content: safeContent,
      })
      const messages = recent.messages.map(messagePayload)

      const payload = {
        chat: chatMetadata(recent.chat),
        nextOffsetId: recent.nextOffsetId?.toString() ?? null,
        since: parsedSince?.toString() ?? null,
        until: parsedUntil?.toString() ?? null,
        content: safeContent,
        messages,
      }

      return {
        structuredContent: payload,
        content: [jsonText(payload)],
      }
    },
  )

  registerInlineTool(
    server,
    resourceMetadataUrl,
    "messages.context",
    {
      title: "Get Inline Message Context",
      description:
        "Use this tool after messages.search, messages.unread, or a known message ID to fetch a before/after window around that message. Omit anchorMessageId to get a compact latest context window.",
      inputSchema: {
        chatId: z.string().min(1).optional().describe("Inline chat ID"),
        userId: z.string().min(1).optional().describe("Inline user ID (DM target)"),
        anchorMessageId: z.string().min(1).optional().describe("Message ID to center the context window around"),
        before: z.number().int().min(0).max(50).default(8).describe("Messages before/older than the anchor"),
        after: z.number().int().min(0).max(50).default(8).describe("Messages after/newer than the anchor"),
        includeAnchor: z.boolean().default(true).describe("Include the anchor message when anchorMessageId is provided"),
        content: z.enum(["all", "links", "media", "photos", "videos", "documents", "files"]).default("all").describe("Content type filter"),
      },
      outputSchema: messagesContextOutputSchema,
      annotations: {
        title: "Get Message Context",
        readOnlyHint: true,
        openWorldHint: false,
      },
      _meta: toolMeta(["messages:read"], "Getting message context...", "Message context loaded"),
    },
    async (
      {
        chatId,
        userId,
        anchorMessageId,
        before,
        after,
        includeAnchor,
        content,
      }: {
        chatId?: string
        userId?: string
        anchorMessageId?: string
        before?: number
        after?: number
        includeAnchor?: boolean
        content?: InlineMessageContentFilter
      },
      extra: { authInfo?: AuthInfo },
    ) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:read")

      const target = parseTarget({ chatId, userId }, "messages.context")
      const safeContent = parseContentFilter(content)
      const context = await params.inline.messageContext({
        ...target,
        ...(anchorMessageId ? { anchorMessageId: parseInlineId(anchorMessageId, "anchorMessageId") } : {}),
        before: before ?? 8,
        after: after ?? 8,
        includeAnchor: includeAnchor !== false,
        content: safeContent,
      })
      const payload = {
        chat: chatMetadata(context.chat),
        anchorMessageId: context.anchorMessageId?.toString() ?? null,
        before: context.before,
        after: context.after,
        includeAnchor: context.includeAnchor,
        content: context.content,
        messages: context.messages.map(messagePayload),
      }
      return {
        structuredContent: payload,
        content: [jsonText(payload)],
      }
    },
  )

  registerInlineTool(
    server,
    resourceMetadataUrl,
    "messages.search",
    {
      title: "Search Inline Messages In Chat",
      description:
        "Use this tool to search within one resolved chatId or DM userId. This is intentionally scoped to a single conversation; use conversations.list first when the target is unclear.",
      inputSchema: {
        chatId: z.string().min(1).optional().describe("Inline chat ID"),
        userId: z.string().min(1).optional().describe("Inline user ID (DM target)"),
        query: z.string().min(1).optional().describe("Optional search query"),
        limit: z.number().int().min(1).max(50).default(20).describe("Maximum messages to return"),
        since: z.string().min(1).optional().describe("Lower time bound"),
        until: z.string().min(1).optional().describe("Upper time bound"),
        content: z.enum(["all", "links", "media", "photos", "videos", "documents", "files"]).default("all").describe("Content type filter"),
      },
      outputSchema: messagesSearchOutputSchema,
      annotations: {
        title: "Search Messages",
        readOnlyHint: true,
        openWorldHint: false,
      },
      _meta: toolMeta(["messages:read"], "Searching messages in chat...", "Message search complete"),
    },
    async (
      {
        chatId,
        userId,
        query,
        limit,
        since,
        until,
        content,
      }: {
        chatId?: string
        userId?: string
        query?: string
        limit?: number
        since?: string
        until?: string
        content?: InlineMessageContentFilter
      },
      extra: { authInfo?: AuthInfo },
    ) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:read")

      const target = parseTarget({ chatId, userId }, "messages.search")
      const parsedSince = parseTimeInput(since, "since")
      const parsedUntil = parseTimeInput(until, "until")
      const safeContent = parseContentFilter(content)
      const found: InlineSearchMessagesResult = await params.inline.searchMessages({
        ...target,
        query,
        limit: limit ?? 20,
        since: parsedSince,
        until: parsedUntil,
        content: safeContent,
      })

      const messages = found.messages.map(messagePayload)

      const payload = {
        query: found.query,
        content: found.content,
        since: parsedSince?.toString() ?? null,
        until: parsedUntil?.toString() ?? null,
        chat: chatMetadata(found.chat),
        messages,
      }

      return {
        structuredContent: payload,
        content: [jsonText(payload)],
      }
    },
  )

  registerInlineTool(
    server,
    resourceMetadataUrl,
    "messages.unread",
    {
      title: "List Unread Inline Messages",
      description:
        "Use this tool to triage unread messages across all approved conversations. Results include chat metadata so you can follow up with messages.list on a specific chatId.",
      inputSchema: {
        limit: z.number().int().min(1).max(200).default(50).describe("Maximum unread messages to return"),
        since: z.string().min(1).optional().describe("Lower time bound"),
        until: z.string().min(1).optional().describe("Upper time bound"),
        content: z.enum(["all", "links", "media", "photos", "videos", "documents", "files"]).default("all").describe("Content type filter"),
      },
      outputSchema: messagesUnreadOutputSchema,
      annotations: {
        title: "Unread Messages",
        readOnlyHint: true,
        openWorldHint: false,
      },
      _meta: toolMeta(["messages:read"], "Listing unread messages...", "Unread messages listed"),
    },
    async (
      { limit, since, until, content }: { limit?: number; since?: string; until?: string; content?: InlineMessageContentFilter },
      extra: { authInfo?: AuthInfo },
    ) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:read")

      const parsedSince = parseTimeInput(since, "since")
      const parsedUntil = parseTimeInput(until, "until")
      const safeContent = parseContentFilter(content)
      const unread = await params.inline.unreadMessages({
        limit: limit ?? 50,
        since: parsedSince,
        until: parsedUntil,
        content: safeContent,
      })

      const items = unread.items.map((item) => ({
        chat: chatMetadata(item.chat),
        message: messagePayload(item.message),
      }))
      const payload = {
        scannedChats: unread.scannedChats,
        since: parsedSince?.toString() ?? null,
        until: parsedUntil?.toString() ?? null,
        content: safeContent,
        items,
      }

      return {
        structuredContent: payload,
        content: [jsonText(payload)],
      }
    },
  )

  registerInlineTool(
    server,
    resourceMetadataUrl,
    "messages.send",
    {
      title: "Send Inline Message",
      description:
        "Use this tool to send one text message after the target is clear. Provide exactly one of chatId or userId; use conversations.list first when resolving a person, DM, thread, or space chat.",
      inputSchema: {
        chatId: z.string().min(1).optional().describe("Inline chat ID"),
        userId: z.string().min(1).optional().describe("Inline user ID (DM target)"),
        text: z.string().min(1).max(8000).describe("Message text"),
        replyToMsgId: z.string().min(1).optional().describe("Reply-to message ID"),
        sendMode: z.enum(["normal", "silent"]).default("normal").describe("Message delivery mode"),
      },
      outputSchema: sendMessageOutputSchema,
      annotations: {
        title: "Send Message",
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false,
      },
      _meta: toolMeta(["messages:write"], "Sending Inline message...", "Message sent"),
    },
    async (
      {
        chatId,
        userId,
        text,
        replyToMsgId,
        sendMode,
      }: {
        chatId?: string
        userId?: string
        text: string
        replyToMsgId?: string
        sendMode?: "normal" | "silent"
      },
      extra: { authInfo?: AuthInfo },
    ) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      const auditBase = {
        grantId: params.grant.id,
        inlineUserId: params.grant.inlineUserId.toString(),
      }

      try {
        requireScope(scopes, "messages:write")

        const target = parseTarget({ chatId, userId }, "messages.send")
        const safeSendMode: "normal" | "silent" = sendMode === "silent" ? "silent" : "normal"
        const res = await params.inline.sendMessage({
          ...target,
          text,
          ...(replyToMsgId ? { replyToMsgId: parseChatId(replyToMsgId) } : {}),
          sendMode: safeSendMode,
          parseMarkdown: true,
        })
        const payload = {
          ok: true,
          ...(chatId ? { chatId } : {}),
          ...(userId ? { userId } : {}),
          messageId: res.messageId?.toString() ?? null,
          metadata: {
            sendMode: safeSendMode,
            ...(replyToMsgId ? { replyToMsgId } : {}),
          },
        }

        logMessagesSendAudit({
          ...auditBase,
          outcome: "success",
          chatId: target.chatId?.toString?.() ?? null,
          spaceId: res.spaceId?.toString() ?? null,
          messageId: res.messageId?.toString() ?? null,
        })

        return {
          structuredContent: payload,
          content: [jsonText(payload)],
        }
      } catch (error) {
        logMessagesSendAudit({
          ...auditBase,
          outcome: "failure",
          chatId: chatId ?? null,
          spaceId: null,
          messageId: null,
        })
        throw error
      }
    },
  )

  return server
}
