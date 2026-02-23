import { Buffer } from "node:buffer"
import { lookup } from "node:dns/promises"
import { isIP } from "node:net"
import * as z from "zod/v4"
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { AuthInfo } from "@modelcontextprotocol/sdk/server/auth/types.js"
import type { McpGrant } from "./grant"
import { MessageEntity_Type, type Message } from "@inline-chat/protocol/core"
import type {
  InlineApi,
  InlineConversationCandidate,
  InlineEligibleChat,
  InlineMessageContentFilter,
  InlineSearchMessagesResult,
  InlineUploadedMediaKind,
} from "../inline/inline-api"
import { logMessagesSendAudit } from "./audit-log"

const MAX_UPLOAD_BYTES = 25 * 1024 * 1024
const MAX_UPLOAD_REDIRECTS = 3
const UPLOAD_FETCH_TIMEOUT_MS = 15_000
const SUPPORTED_PHOTO_MIME = new Set(["image/jpeg", "image/png", "image/gif", "image/webp"])
const SUPPORTED_VIDEO_MIME = new Set(["video/mp4"])

type RequestedUploadKind = "auto" | InlineUploadedMediaKind

type ResolvedUploadSource = {
  sourceKind: "base64" | "url"
  bytes: Uint8Array
  inferredContentType?: string
  inferredFileName?: string
  sourceRef: string | null
}

type SendMode = "normal" | "silent"

type SendBatchItem =
  | {
      type: "text"
      text: string
      replyToMsgId?: string
      sendMode?: SendMode
      parseMarkdown?: boolean
    }
  | {
      type: "media"
      mediaKind: InlineUploadedMediaKind
      mediaId: string
      text?: string
      replyToMsgId?: string
      sendMode?: SendMode
      parseMarkdown?: boolean
    }

function requireScope(scopes: string[], needed: string): void {
  if (!scopes.includes(needed)) {
    throw new Error(`insufficient scope: requires ${needed}`)
  }
}

function jsonText(obj: unknown): { type: "text"; text: string } {
  return { type: "text", text: JSON.stringify(obj) }
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
  const sanitized = noQuery.replace(/[\u0000-\u001f\u007f]/g, "").trim()
  return sanitized
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
      kind: "photo" | "video" | "document" | "nudge"
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
  return {
    kind: "nudge",
    id: null,
    url: null,
  }
}

function messagePayload(message: Message) {
  const snippet = snippetOf(message.message)
  const media = messageMediaSummary(message)
  const links = extractMessageUrls(message)
  return {
    id: message.id.toString(),
    text: message.message ?? "",
    ...(snippet ? { snippet } : {}),
    out: message.out === true,
    hasLink: message.hasLink === true || links.length > 0,
    links,
    media,
    metadata: {
      chatId: message.chatId.toString(),
      fromId: message.fromId?.toString?.() ?? null,
      date: message.date?.toString?.() ?? null,
      replyToMsgId: message.replyToMsgId?.toString() ?? null,
    },
  }
}

function chatMetadata(chat: InlineEligibleChat): {
  chatId: string
  title: string
  kind: "dm" | "home_thread" | "space_chat"
  spaceId: string | null
  spaceName: string | null
  peer: { userId: string | null; displayName: string | null; username: string | null } | null
  metadata: {
    chatTitle: string
    archived: boolean
    pinned: boolean
    unreadCount: number
    readMaxId: string | null
    lastMessageId: string | null
    lastMessageDate: string | null
  }
} {
  const peer =
    chat.peerUserId != null || chat.peerDisplayName != null || chat.peerUsername != null
      ? {
          userId: chat.peerUserId?.toString() ?? null,
          displayName: chat.peerDisplayName ?? null,
          username: chat.peerUsername ?? null,
        }
      : null

  return {
    chatId: chat.chatId.toString(),
    title: sourceTitle(chat.title, chat.chatId),
    kind: chat.kind,
    spaceId: chat.spaceId?.toString() ?? null,
    spaceName: chat.spaceName ?? null,
    peer,
    metadata: {
      chatTitle: chat.chatTitle,
      archived: chat.archived,
      pinned: chat.pinned,
      unreadCount: chat.unreadCount,
      readMaxId: chat.readMaxId?.toString() ?? null,
      lastMessageId: chat.lastMessageId?.toString() ?? null,
      lastMessageDate: chat.lastMessageDate?.toString() ?? null,
    },
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

export function createInlineMcpServer(params: {
  grant: McpGrant
  inline: InlineApi
}): McpServer {
  const server = new McpServer(
    {
      name: "inline",
      version: "0.1.0",
    },
    {
      capabilities: {
        tools: { listChanged: false },
      },
    },
  )

  server.registerTool(
    "conversations.list",
    {
      title: "List Inline Conversations",
      description: "List recent conversations or find by contact name/chat title/chat ID.",
      inputSchema: {
        query: z.string().min(1).optional().describe("Optional contact name, chat title, or chat ID"),
        limit: z.number().int().min(1).max(50).default(20).describe("Maximum conversations to return"),
        unreadOnly: z.boolean().default(false).describe("Only include conversations with unread messages"),
      },
      annotations: {
        title: "List Conversations",
        readOnlyHint: true,
        openWorldHint: false,
      },
      _meta: toolMeta(["messages:read"], "Listing Inline conversations...", "Conversations listed"),
    },
    async ({ query, limit, unreadOnly }: { query?: string; limit?: number; unreadOnly?: boolean }, extra: { authInfo?: AuthInfo }) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:read")

      const safeLimit = Math.max(1, Math.min(50, limit ?? 20))
      const safeQuery = query?.trim()
      const onlyUnread = unreadOnly === true

      if (!safeQuery) {
        const chats = await params.inline.getEligibleChats()
        const filtered = onlyUnread ? chats.filter((chat) => chat.unreadCount > 0) : chats
        const items = filtered.slice(0, safeLimit).map((chat, index) => conversationListItem(chat, index + 1))
        const payload = {
          query: null,
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
      const items = filtered.map((candidate: InlineConversationCandidate, index: number) =>
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

  server.registerTool(
    "conversations.create",
    {
      title: "Create Inline Conversation",
      description: "Create a new thread/chat in an allowed space or home threads.",
      inputSchema: {
        title: z.string().min(1).max(200).describe("Conversation title"),
        spaceId: z.string().min(1).optional().describe("Parent space ID for a thread"),
        description: z.string().max(1000).optional().describe("Optional description"),
        emoji: z.string().max(16).optional().describe("Optional emoji icon"),
        isPublic: z.boolean().default(false).describe("Whether the conversation is public"),
        participantUserIds: z.array(z.string().min(1)).max(50).default([]).describe("Participant user IDs (for private chats)"),
      },
      annotations: {
        title: "Create Conversation",
        readOnlyHint: false,
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

  server.registerTool(
    "files.upload",
    {
      title: "Upload File For Inline Media",
      description: "Upload media (base64 or URL source) and return Inline media IDs for sending messages.",
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
      annotations: {
        title: "Upload File",
        readOnlyHint: false,
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

  server.registerTool(
    "messages.send_media",
    {
      title: "Send Inline Media Message",
      description: "Send uploaded media (photo/video/document) to a chat or DM, optionally with caption text.",
      inputSchema: {
        chatId: z.string().min(1).optional().describe("Inline chat ID"),
        userId: z.string().min(1).optional().describe("Inline user ID (DM target)"),
        mediaKind: z.enum(["photo", "video", "document"]).describe("Uploaded media kind"),
        mediaId: z.string().min(1).describe("Uploaded media ID"),
        text: z.string().max(8000).optional().describe("Optional caption text"),
        replyToMsgId: z.string().min(1).optional().describe("Reply-to message ID"),
        sendMode: z.enum(["normal", "silent"]).default("normal").describe("Message delivery mode"),
        parseMarkdown: z.boolean().default(true).describe("Parse markdown formatting for caption"),
      },
      annotations: {
        title: "Send Media Message",
        readOnlyHint: false,
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
        parseMarkdown,
      }: {
        chatId?: string
        userId?: string
        mediaKind: InlineUploadedMediaKind
        mediaId: string
        text?: string
        replyToMsgId?: string
        sendMode?: "normal" | "silent"
        parseMarkdown?: boolean
      },
      extra: { authInfo?: AuthInfo },
    ) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:write")

      const target = parseTarget({ chatId, userId }, "messages.send_media")
      const safeSendMode: "normal" | "silent" = sendMode === "silent" ? "silent" : "normal"
      const safeParseMarkdown = parseMarkdown ?? true
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
        parseMarkdown: safeParseMarkdown,
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
          parseMarkdown: safeParseMarkdown,
          ...(replyToMsgId ? { replyToMsgId } : {}),
        },
      }
      return {
        structuredContent: payload,
        content: [jsonText(payload)],
      }
    },
  )

  server.registerTool(
    "messages.send_batch",
    {
      title: "Send Inline Message Batch",
      description: "Send a list of text and media items in order to a chat or DM.",
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
                parseMarkdown: z.boolean().default(true),
              }),
              z.object({
                type: z.literal("media"),
                mediaKind: z.enum(["photo", "video", "document"]),
                mediaId: z.string().min(1),
                text: z.string().max(8000).optional(),
                replyToMsgId: z.string().min(1).optional(),
                sendMode: z.enum(["normal", "silent"]).default("normal"),
                parseMarkdown: z.boolean().default(true),
              }),
            ]),
          )
          .min(1)
          .max(100)
          .describe("Ordered list of message items"),
      },
      annotations: {
        title: "Send Message Batch",
        readOnlyHint: false,
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
          const safeParseMarkdown = item.parseMarkdown ?? true
          if (item.type === "text") {
            const sent = await params.inline.sendMessage({
              ...target,
              text: item.text,
              ...(item.replyToMsgId ? { replyToMsgId: parseInlineId(item.replyToMsgId, "replyToMsgId") } : {}),
              sendMode: safeSendMode,
              parseMarkdown: safeParseMarkdown,
            })
            sentCount += 1
            results.push({
              index,
              type: "text",
              status: "sent",
              messageId: sent.messageId?.toString() ?? null,
              metadata: {
                sendMode: safeSendMode,
                parseMarkdown: safeParseMarkdown,
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
            parseMarkdown: safeParseMarkdown,
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
              parseMarkdown: safeParseMarkdown,
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

  server.registerTool(
    "messages.list",
    {
      title: "List Inline Messages",
      description: "List recent messages for a chat.",
      inputSchema: {
        chatId: z.string().min(1).optional().describe("Inline chat ID"),
        userId: z.string().min(1).optional().describe("Inline user ID (DM target)"),
        direction: z.enum(["sent", "all"]).default("all").describe("`sent` returns only outgoing messages"),
        limit: z.number().int().min(1).max(50).default(20).describe("Maximum messages to return"),
        offsetId: z.string().min(1).optional().describe("Fetch messages older than this message ID"),
        since: z.string().min(1).optional().describe("Lower time bound (e.g. yesterday, 2d ago, 2026-02-20)"),
        until: z.string().min(1).optional().describe("Upper time bound"),
        unreadOnly: z.boolean().default(false).describe("Only include unread messages"),
        content: z.enum(["all", "links", "media", "photos", "videos", "documents", "files"]).default("all").describe("Content type filter"),
      },
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
        direction,
        limit,
        offsetId,
        since,
        until,
        unreadOnly,
        content,
      }: {
        chatId?: string
        userId?: string
        direction?: "sent" | "all"
        limit?: number
        offsetId?: string
        since?: string
        until?: string
        unreadOnly?: boolean
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
        direction: direction ?? "all",
        limit: limit ?? 20,
        offsetId: parsedOffsetId,
        since: parsedSince,
        until: parsedUntil,
        unreadOnly: unreadOnly === true,
        content: safeContent,
      })
      const messages = recent.messages.map(messagePayload)

      const payload = {
        chat: chatMetadata(recent.chat),
        direction: recent.direction,
        scannedCount: recent.scannedCount,
        nextOffsetId: recent.nextOffsetId?.toString() ?? null,
        unreadOnly: unreadOnly === true,
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

  server.registerTool(
    "messages.search",
    {
      title: "Search Inline Messages In Chat",
      description: "Search messages in a specific chat (no global search).",
      inputSchema: {
        chatId: z.string().min(1).optional().describe("Inline chat ID"),
        userId: z.string().min(1).optional().describe("Inline user ID (DM target)"),
        query: z.string().min(1).optional().describe("Optional search query"),
        limit: z.number().int().min(1).max(50).default(20).describe("Maximum messages to return"),
        since: z.string().min(1).optional().describe("Lower time bound"),
        until: z.string().min(1).optional().describe("Upper time bound"),
        content: z.enum(["all", "links", "media", "photos", "videos", "documents", "files"]).default("all").describe("Content type filter"),
      },
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
        mode: found.mode,
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

  server.registerTool(
    "messages.unread",
    {
      title: "List Unread Inline Messages",
      description: "List unread messages across approved conversations.",
      inputSchema: {
        limit: z.number().int().min(1).max(200).default(50).describe("Maximum unread messages to return"),
        since: z.string().min(1).optional().describe("Lower time bound"),
        until: z.string().min(1).optional().describe("Upper time bound"),
        content: z.enum(["all", "links", "media", "photos", "videos", "documents", "files"]).default("all").describe("Content type filter"),
      },
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

  server.registerTool(
    "messages.send",
    {
      title: "Send Inline Message",
      description: "Send a message to a chat in your approved spaces, DMs, or home threads.",
      inputSchema: {
        chatId: z.string().min(1).optional().describe("Inline chat ID"),
        userId: z.string().min(1).optional().describe("Inline user ID (DM target)"),
        text: z.string().min(1).max(8000).describe("Message text"),
        replyToMsgId: z.string().min(1).optional().describe("Reply-to message ID"),
        sendMode: z.enum(["normal", "silent"]).default("normal").describe("Message delivery mode"),
        parseMarkdown: z.boolean().default(true).describe("Parse markdown formatting"),
      },
      annotations: {
        title: "Send Message",
        readOnlyHint: false,
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
        parseMarkdown,
      }: {
        chatId?: string
        userId?: string
        text: string
        replyToMsgId?: string
        sendMode?: "normal" | "silent"
        parseMarkdown?: boolean
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
        const safeParseMarkdown = parseMarkdown ?? true
        const res = await params.inline.sendMessage({
          ...target,
          text,
          ...(replyToMsgId ? { replyToMsgId: parseChatId(replyToMsgId) } : {}),
          sendMode: safeSendMode,
          parseMarkdown: safeParseMarkdown,
        })
        const payload = {
          ok: true,
          ...(chatId ? { chatId } : {}),
          ...(userId ? { userId } : {}),
          messageId: res.messageId?.toString() ?? null,
          metadata: {
            sendMode: safeSendMode,
            parseMarkdown: safeParseMarkdown,
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
