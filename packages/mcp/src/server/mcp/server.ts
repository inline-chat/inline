import { Buffer } from "node:buffer"
import { lookup } from "node:dns/promises"
import { request as httpsRequest } from "node:https"
import { BlockList, isIP } from "node:net"
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
  InlineMessagesResult,
  InlinePersonCandidate,
  InlinePersonSummary,
  InlineSpaceSummary,
  InlineSearchMessagesResult,
  InlineUploadedMediaKind,
} from "../inline/inline-api"
import { logMessagesSendAudit } from "./audit-log"
import { MESSAGE_RESULTS_RESOURCE_URI, registerMessageResultsUi } from "./message-results-ui"
import { registerConversationMentions } from "./conversation-mentions"

const MAX_UPLOAD_BYTES = 25 * 1024 * 1024
const MAX_UPLOAD_REDIRECTS = 3
const UPLOAD_DNS_TIMEOUT_MS = 5_000
const UPLOAD_FETCH_TIMEOUT_MS = 15_000
const SUPPORTED_PHOTO_MIME = new Set(["image/jpeg", "image/png", "image/gif", "image/webp"])
const SUPPORTED_VIDEO_MIME = new Set(["video/mp4"])
const DEFAULT_RESOURCE_METADATA_URL = "https://mcp.inline.chat/.well-known/oauth-protected-resource"
const INLINE_MCP_INSTRUCTIONS =
  "Inline MCP gives scoped access to the user's work chats. Resolve people, spaces, or thread names with people.search, spaces.list, and conversations.list before using chatId; inspect a target with conversations.get. For summaries, analysis, comparisons, or drafting, silently read and page messages.list/search/context/unread, deduplicate IDs, and state actual returned coverage; these data tools do not display cards. Use messages.view only when original evidence or conversation browsing adds value or is requested: sources selects ordered canonical originals across chats; catch_up reads real paged history without marking read. A view's selected or loaded count does not certify how many messages were analyzed. Send only after the target is clear. IDs are strings. Time filters accept today, yesterday, 2d ago, YYYY-MM-DD, or epoch seconds. Use account.me to inspect scopes and allowed chat contexts."

const INLINE_MARKDOWN_HELP =
  'Parsed as supported Inline Markdown: **bold**, *italic*, <u>underline</u>, ~~strikethrough~~, ==highlight==, `code`, fenced code (optional language), four-space indented code, [label](https://example.com), [Name](inline://user?id=42), [[Title]](inline://chat?id=123), # headings, - bullets, 1. numbered lists, - [ ] / - [x] checklists, > quotes, pipe tables with a header separator row, --- separators, and ![alt](https://example.com/image.png). Math uses $TeX$ inline or $$TeX$$ on separate lines for display. Disclosures use <details open> / <summary>Title</summary> / body / </details> on separate lines; omit open to start collapsed and use <summary kind="progress"> only while working. Use <footer>metadata</footer> on its own line. Preserve indentation/newlines; use backslash escapes or code for literal syntax. Do not fence the whole message or tables unless literal code is intended. Footnotes and arbitrary HTML are unsupported. Rich formatting and math rendering depend on the recipient client.'

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

export type McpToolContract = "legacy" | "submission-v2"

// Keep the deployed /mcp descriptors and behavior intact for cached or hand-written clients.
// /mcp/v2 selects the explicit branches below so submission scanners never see legacy ambiguity.

type SendBatchItem = {
  type: "text" | InlineUploadedMediaKind
  content: string
}

type LegacySendBatchItem = {
  type: "text" | "media"
  text?: string
  mediaKind?: InlineUploadedMediaKind
  mediaId?: string
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
  const [a, b, c] = octets
  if (a === 10) return true
  if (a === 127) return true
  if (a === 169 && b === 254) return true
  if (a === 172 && b >= 16 && b <= 31) return true
  if (a === 192 && b === 168) return true
  if (a === 100 && b >= 64 && b <= 127) return true
  if (a === 0) return true
  if (a === 192 && b === 0 && c === 0) return true
  if (a === 192 && b === 0 && c === 2) return true
  if (a === 192 && b === 31 && c === 196) return true
  if (a === 192 && b === 52 && c === 193) return true
  if (a === 192 && b === 88 && c === 99) return true
  if (a === 192 && b === 175 && c === 48) return true
  if (a === 198 && (b === 18 || b === 19)) return true
  if (a === 198 && b === 51 && c === 100) return true
  if (a === 203 && b === 0 && c === 113) return true
  if (a >= 224) return true
  return false
}

const globalIpv6Range = new BlockList()
globalIpv6Range.addSubnet("2000::", 3, "ipv6")
const specialIpv6Ranges = new BlockList()
specialIpv6Ranges.addSubnet("2001::", 23, "ipv6")
specialIpv6Ranges.addSubnet("2001:db8::", 32, "ipv6")
specialIpv6Ranges.addSubnet("2002::", 16, "ipv6")
specialIpv6Ranges.addSubnet("3fff::", 20, "ipv6")

function isPrivateIpv6(address: string): boolean {
  const lowered = address.toLowerCase().split("%", 1)[0] ?? ""
  if (!lowered) return true
  return !globalIpv6Range.check(lowered, "ipv6") || specialIpv6Ranges.check(lowered, "ipv6")
}

export function isUnsafeRemoteAddress(address: string): boolean {
  const ipVersion = isIP(address)
  if (ipVersion === 4) return isPrivateIpv4(address)
  if (ipVersion === 6) return isPrivateIpv6(address)
  return true
}

async function resolveSafeRemoteAddress(url: URL): Promise<{ address: string; hostname: string }> {
  if (url.protocol !== "https:") {
    throw new Error("url must use https")
  }
  if (url.username || url.password) {
    throw new Error("url must not include credentials")
  }

  const rawHostname = url.hostname.trim().toLowerCase()
  const hostname = (rawHostname.startsWith("[") && rawHostname.endsWith("]")
    ? rawHostname.slice(1, -1)
    : rawHostname).replace(/\.+$/, "")
  if (!hostname) throw new Error("invalid url hostname")
  if (hostname === "localhost" || hostname.endsWith(".localhost") || hostname.endsWith(".local")) {
    throw new Error("url host is not allowed")
  }

  if (isIP(hostname)) {
    if (isUnsafeRemoteAddress(hostname)) {
      throw new Error("url host resolves to a private or local address")
    }
    return { address: hostname, hostname }
  }

  let resolved: { address: string }[]
  let dnsTimer: ReturnType<typeof setTimeout> | undefined
  try {
    resolved = await Promise.race([
      lookup(hostname, { all: true, verbatim: true }),
      new Promise<never>((_, reject) => {
        dnsTimer = setTimeout(() => reject(new Error("dns lookup timed out")), UPLOAD_DNS_TIMEOUT_MS)
      }),
    ])
  } catch {
    throw new Error("unable to resolve url host")
  } finally {
    if (dnsTimer) clearTimeout(dnsTimer)
  }
  if (resolved.length === 0) throw new Error("unable to resolve url host")
  for (const address of resolved) {
    if (isUnsafeRemoteAddress(address.address)) {
      throw new Error("url host resolves to a private or local address")
    }
  }
  return { address: resolved[0]!.address, hostname }
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

type PinnedHttpsResponse = { status: number; headers: Headers; bytes: Uint8Array }

function fetchPinnedHttps(url: URL, target: { address: string; hostname: string }): Promise<PinnedHttpsResponse> {
  return new Promise((resolve, reject) => {
    let settled = false
    let timer: ReturnType<typeof setTimeout> | undefined
    const finish = (result: PinnedHttpsResponse) => {
      if (settled) return
      settled = true
      if (timer) clearTimeout(timer)
      resolve(result)
    }
    const fail = (error: unknown) => {
      if (settled) return
      settled = true
      if (timer) clearTimeout(timer)
      reject(error)
    }

    const request = httpsRequest({
      protocol: "https:",
      hostname: target.address,
      port: url.port ? Number(url.port) : 443,
      method: "GET",
      path: `${url.pathname}${url.search}`,
      servername: isIP(target.hostname) ? undefined : target.hostname,
      rejectUnauthorized: true,
      headers: { accept: "*/*", "accept-encoding": "identity", host: url.host },
    }, (response) => {
      const headers = new Headers()
      for (const [name, value] of Object.entries(response.headers)) {
        if (Array.isArray(value)) {
          for (const item of value) headers.append(name, item)
        } else if (value !== undefined) {
          headers.set(name, value)
        }
      }
      const status = response.statusCode ?? 502
      if (isRedirectStatus(status) || status < 200 || status >= 300) {
        response.destroy()
        finish({ status, headers, bytes: new Uint8Array() })
        return
      }

      const contentEncoding = headers.get("content-encoding")?.trim().toLowerCase()
      if (contentEncoding && contentEncoding !== "identity") {
        response.destroy()
        fail(new Error("url source returned unsupported content encoding"))
        return
      }

      const contentLengthHeader = headers.get("content-length")
      if (contentLengthHeader) {
        const parsed = Number(contentLengthHeader)
        if (Number.isFinite(parsed) && parsed > MAX_UPLOAD_BYTES) {
          response.destroy()
          fail(new Error(`file exceeds ${MAX_UPLOAD_BYTES} bytes limit`))
          return
        }
      }

      const chunks: Buffer[] = []
      let total = 0
      response.on("data", (chunk: Buffer) => {
        total += chunk.byteLength
        if (total > MAX_UPLOAD_BYTES) {
          response.destroy()
          fail(new Error(`file exceeds ${MAX_UPLOAD_BYTES} bytes limit`))
          return
        }
        chunks.push(chunk)
      })
      response.once("end", () => {
        const bytes = Buffer.concat(chunks, total)
        finish({ status, headers, bytes: Uint8Array.from(bytes) })
      })
      response.once("error", fail)
    })
    request.once("error", fail)
    timer = setTimeout(() => request.destroy(new Error("url source request timed out")), UPLOAD_FETCH_TIMEOUT_MS)
    request.end()
  })
}

export async function loadUploadSourceFromUrl(urlInput: string): Promise<ResolvedUploadSource> {
  let current: URL
  try {
    current = new URL(urlInput)
  } catch {
    throw new Error("invalid url")
  }

  for (let redirectCount = 0; redirectCount <= MAX_UPLOAD_REDIRECTS; redirectCount++) {
    const target = await resolveSafeRemoteAddress(current)
    let response: PinnedHttpsResponse
    try {
      response = await fetchPinnedHttps(current, target)
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      throw new Error(`failed to fetch url source (${message})`)
    }

    if (isRedirectStatus(response.status)) {
      const location = response.headers.get("location")
      if (!location) throw new Error("redirect response missing location header")
      current = new URL(location, current)
      continue
    }

    if (response.status < 200 || response.status >= 300) {
      throw new Error(`url source responded with status ${response.status}`)
    }
    const bytes = response.bytes
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

function namedMessagePayload(message: Message, senderDisplayNames?: Record<string, string>) {
  const name = senderDisplayNames?.[message.fromId?.toString() ?? ""]
  return { ...messagePayload(message), ...(name ? { senderDisplayName: name } : {}) }
}

// Presentation requests accept identities only. Canonical text is freshly read,
// bounded for display, and kept apart from expiring signed browser URLs.
function presentationString(value: string, maxBytes: number): string {
  if (Buffer.byteLength(JSON.stringify(value)) <= maxBytes) return value
  let low = 0
  let high = value.length
  while (low < high) {
    const middle = Math.ceil((low + high) / 2)
    if (Buffer.byteLength(JSON.stringify(value.slice(0, middle))) <= maxBytes) low = middle
    else high = middle - 1
  }
  if (low && /[\uD800-\uDBFF]/.test(value[low - 1]) && /[\uDC00-\uDFFF]/.test(value[low] ?? "")) low -= 1
  return value.slice(0, low)
}

function signedPresentationUrl(value: string | null | undefined): string | null {
  if (!value || value.length > 4096) return null
  try {
    const url = new URL(value)
    if (url.origin !== "https://api.inline.chat" || url.pathname !== "/file" || url.username || url.password || url.hash) return null
    if (!["id", "exp", "sig"].every((key) => url.searchParams.get(key))) return null
    const expires = url.searchParams.get("exp")!
    if (!/^\d+$/.test(expires) || !Number.isFinite(Number(expires)) || Number(expires) <= Date.now() / 1000) return null
    return url.href
  } catch { return null }
}

function signedOriginalPresentationUrl(value: string | null | undefined, fileUniqueId: string | undefined): string | null {
  const proxy = signedPresentationUrl(value)
  if (proxy) return proxy
  if (!value || value.length > 4096 || !fileUniqueId || !/^[A-Za-z0-9_-]{6,128}$/.test(fileUniqueId)) return null
  try {
    const url = new URL(value)
    // Documents, video and voice deliberately retain direct R2 capabilities in
    // the realtime encoders. These originals are only opened by the host, never
    // embedded or added to the widget CSP. R2 verifies the actual signature;
    // here we validate the canonical provider, file identity and expiry shape.
    if (url.protocol !== "https:" || !/^[a-f0-9]{32}\.r2\.cloudflarestorage\.com$/.test(url.hostname) || url.port || url.username || url.password || url.hash) return null
    const path = url.pathname.split("/").map((part) => decodeURIComponent(part))
    if (path.length !== 5 || !path[1] || path[2] !== "files" || path[3] !== fileUniqueId || !path[4] || path.some((part) => part.includes("/") || part === "." || part === "..")) return null
    const keys = ["X-Amz-Algorithm", "X-Amz-Credential", "X-Amz-Date", "X-Amz-Expires", "X-Amz-SignedHeaders", "X-Amz-Signature"]
    if (keys.some((key) => url.searchParams.getAll(key).length !== 1)) return null
    if (url.searchParams.get("X-Amz-Algorithm") !== "AWS4-HMAC-SHA256" || url.searchParams.get("X-Amz-SignedHeaders") !== "host" || !/^[a-f0-9]{64}$/.test(url.searchParams.get("X-Amz-Signature")!)) return null
    const date = url.searchParams.get("X-Amz-Date")!
    if (!/^\d{8}T\d{6}Z$/.test(date)) return null
    const credential = url.searchParams.get("X-Amz-Credential")!
    if (!new RegExp(`^[A-Za-z0-9]+/${date.slice(0, 8)}/auto/s3/aws4_request$`).test(credential)) return null
    const signedAt = Date.parse(`${date.slice(0, 4)}-${date.slice(4, 6)}-${date.slice(6, 8)}T${date.slice(9, 11)}:${date.slice(11, 13)}:${date.slice(13, 15)}Z`)
    if (!Number.isFinite(signedAt) || signedAt > Date.now() + 15 * 60 * 1000 || new Date(signedAt).toISOString().replace(/[-:]/g, "").replace(".000", "") !== date) return null
    const expires = url.searchParams.get("X-Amz-Expires")!
    if (!/^\d+$/.test(expires) || Number(expires) < 1 || Number(expires) > 604800 || signedAt + Number(expires) * 1000 <= Date.now()) return null
    return url.href
  } catch { return null }
}

function presentationMedia(message: Message): { thumbnailUrl: string | null; originalUrl: string | null; originalFileUniqueId?: string } {
  const media = message.media?.media
  const value = media?.oneofKind === "photo" ? media.photo.photo
    : media?.oneofKind === "video" ? media.video.video
    : media?.oneofKind === "document" ? media.document.document
    : media?.oneofKind === "voice" ? media.voice.voice : undefined
  const photo = media?.oneofKind === "photo" ? media.photo.photo
    : media?.oneofKind === "video" ? media.video.video?.photo
    : media?.oneofKind === "document" ? media.document.document?.photo : undefined
  const sizes = (photo?.sizes ?? []).filter((size) => signedPresentationUrl(size.cdnUrl))
  const thumbnails = sizes.filter((size) => size.w > 0 && size.h > 0 && Math.max(size.w, size.h) <= 800)
    .sort((left, right) => Math.abs(Math.max(left.w, left.h) - 320) - Math.abs(Math.max(right.w, right.h) - 320))
  const original = media?.oneofKind === "photo" ? bestPhotoSize({ sizes }).cdnUrl
    : value && "cdnUrl" in value ? value.cdnUrl : null
  const candidateFileUniqueId = media?.oneofKind !== "photo" ? value?.fileUniqueId : undefined
  const fileUniqueId = candidateFileUniqueId && /^[A-Za-z0-9_-]{6,128}$/.test(candidateFileUniqueId) ? candidateFileUniqueId : undefined
  return {
    thumbnailUrl: signedPresentationUrl(thumbnails[0]?.cdnUrl),
    originalUrl: media?.oneofKind === "photo" ? signedPresentationUrl(original) : signedOriginalPresentationUrl(original, fileUniqueId),
    ...(fileUniqueId ? { originalFileUniqueId: fileUniqueId } : {}),
  }
}

function presentationMessage(message: Message, result: InlineMessagesResult) {
  const base = namedMessagePayload(message, result.senderDisplayNames)
  const original = base.text
  const text = presentationString(original, 6000)
  const entities = (message.entities?.entities ?? []).slice(0, 64).flatMap((entity) => {
    const offset = Number(entity.offset)
    const length = Number(entity.length)
    if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length <= 0 || offset + length > text.length) return []
    const details = entity.entity
    return [{ type: entity.type, offset, length,
      ...(details.oneofKind === "textUrl" ? { url: presentationString(details.textUrl.url, 512) } : {}),
      ...(details.oneofKind === "pre" ? { language: presentationString(details.pre.language, 64) } : {}),
      ...(details.oneofKind === "mention" ? { userId: details.mention.userId.toString() } : {}),
      ...(details.oneofKind === "thread" ? { chatId: details.thread.chatId.toString() } : {}),
    }]
  })
  const reply = [...result.messages, ...result.replyMessages ?? []].find((candidate) => candidate.chatId === message.chatId && candidate.id === message.replyToMsgId)
  const replyMedia = reply ? messageMediaSummary(reply) : null
  const service = message.serviceMessage?.event
  const serviceMessage = service?.oneofKind === "threadBacklink"
    ? { kind: "thread_backlink" as const, ...(service.threadBacklink.sourceChatId != null ? { chatId: service.threadBacklink.sourceChatId.toString() } : {}), ...(service.threadBacklink.sourceTitle ? { title: presentationString(service.threadBacklink.sourceTitle, 512) } : {}) }
    : service?.oneofKind === "pinnedMessage" ? { kind: "pinned_message" as const, ...(service.pinnedMessage.messageId != null ? { messageId: service.pinnedMessage.messageId.toString() } : {}) } : undefined
  const payload = {
    ...base, text, snippet: snippetOf(text),
    ...(base.senderDisplayName ? { senderDisplayName: presentationString(base.senderDisplayName, 256) } : {}),
    media: base.media ? { ...base.media, url: null, ...(base.media.fileName ? { fileName: presentationString(base.media.fileName, 512) } : {}), ...(base.media.mimeType ? { mimeType: presentationString(base.media.mimeType, 256) } : {}) } : null,
    links: base.links.slice(0, 8).map((link) => presentationString(link, 512)).filter((link) => !signedPresentationUrl(link)),
    // Rich preview metadata remains in data tools; the small reader uses the
    // original link and media row without exposing additional signed URLs.
    urlPreviews: [], externalTasks: [], entities,
    ...(serviceMessage ? { serviceMessage } : {}),
    ...(reply ? { replyToMessage: {
      id: reply.id.toString(), text: presentationString(reply.message ?? "", 512),
      fromId: reply.fromId?.toString() ?? null, out: reply.out === true,
      ...(result.senderDisplayNames?.[reply.fromId?.toString() ?? ""] ? { senderDisplayName: presentationString(result.senderDisplayNames[reply.fromId!.toString()], 256) } : {}),
      media: replyMedia ? { ...replyMedia, url: null, ...(replyMedia.fileName ? { fileName: presentationString(replyMedia.fileName, 512) } : {}), ...(replyMedia.mimeType ? { mimeType: presentationString(replyMedia.mimeType, 256) } : {}) } : null,
    } } : {}),
    ...(text !== original ? { textTruncated: true } : {}),
  }
  // Ranges and links can be large independently of text. Bound each row so a
  // 50-message history page stays below the 512 KiB presentation budget.
  if (Buffer.byteLength(JSON.stringify(payload)) > 8192) {
    payload.entities = []
    payload.links = []
  }
  return payload
}

function presentationReadAuth(grant: McpGrant, auth: AuthInfo | undefined): AuthInfo {
  if (!auth || auth.clientId !== grant.clientId || (auth.expiresAt != null && auth.expiresAt <= Date.now() / 1000)
    || (auth.extra?.grantId != null && auth.extra.grantId !== grant.id)
    || (auth.extra?.inlineUserId != null && auth.extra.inlineUserId !== grant.inlineUserId.toString())) {
    throw new Error("Inline MCP authorization is missing, expired, or belongs to another grant")
  }
  requireScope(auth.scopes, "messages:read")
  requireScope(grant.scope.split(/\s+/), "messages:read")
  return auth
}

function presentationChatAllowed(chat: InlineEligibleChat, grant: McpGrant, auth: AuthInfo): boolean {
  if (chat.kind === "dm") return grant.allowDms && auth.extra?.allowDms !== false
  if (chat.kind === "home_thread") return grant.allowHomeThreads && auth.extra?.allowHomeThreads !== false
  if (chat.spaceId == null || !grant.spaceIds.includes(chat.spaceId)) return false
  return !Array.isArray(auth.extra?.spaceIds) || auth.extra.spaceIds.includes(chat.spaceId.toString())
}

async function presentationMap<T, R>(items: T[], fn: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = []
  let cursor = 0
  await Promise.all(Array.from({ length: Math.min(4, items.length) }, async () => {
    while (cursor < items.length) {
      const index = cursor++
      results[index] = await fn(items[index])
    }
  }))
  return results
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
  senderDisplayName: z.string().optional(),
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
  entities: z.array(z.object({
    type: z.number(), offset: z.number(), length: z.number(), url: z.string().optional(), language: z.string().optional(), userId: z.string().optional(), chatId: z.string().optional(),
  })).optional(),
  textTruncated: z.boolean().optional(),
  replyToMessage: z.object({
    id: z.string(), text: z.string(), fromId: z.string().nullable(), out: z.boolean(), senderDisplayName: z.string().optional(), media: messageMediaOutputSchema,
  }).optional(),
  serviceMessage: z.object({
    kind: z.enum(["thread_backlink", "pinned_message"]), chatId: z.string().optional(), title: z.string().optional(), messageId: z.string().optional(),
  }).optional(),
})

const messageViewOutputSchema = z.object({
  presentation: z.enum(["sources", "catch_up"]),
  chats: z.array(z.object({
    chatId: z.string(), status: z.enum(["available", "unavailable"]),
    chat: chatMetadataOutputSchema.extend({ lastMessagePreview: z.string().nullable().optional() }).nullable(),
  })),
  items: z.array(z.object({
    chatId: z.string(), messageId: z.string(), status: z.enum(["available", "unavailable"]), message: messageOutputSchema.nullable(),
  })),
  activeChatId: z.string().nullable(),
  page: z.object({
    kind: z.enum(["selected", "latest", "older", "newer", "context", "unread"]), nextOffsetId: z.string().nullable(), nextAfterId: z.string().nullable(),
    anchorMessageId: z.string().nullable(), firstUnreadMessageId: z.string().nullable(), note: z.string().nullable(),
  }),
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
  chatId: z.string(),
  text: z.string().optional(),
  messageId: z.string().nullable(),
  metadata: sendMetadataOutputSchema,
})

const legacySendMessageOutputSchema = z.object({
  ok: z.boolean(),
  chatId: z.string().optional(),
  userId: z.string().optional(),
  text: z.string().optional(),
  messageId: z.string().nullable(),
  metadata: sendMetadataOutputSchema,
})

const sendMediaMessageOutputSchema = z.object({
  ok: z.boolean(),
  chatId: z.string(),
  media: z.object({
    kind: z.enum(["photo", "video", "document"]),
    id: z.string(),
  }),
  text: z.string().optional(),
  messageId: z.string().nullable(),
  metadata: sendMetadataOutputSchema,
})

const legacySendMediaMessageOutputSchema = z.object({
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
  type: z.enum(["text", "photo", "video", "document"]),
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
  chatId: z.string(),
  stopOnError: z.boolean(),
  total: z.number(),
  sentCount: z.number(),
  failedCount: z.number(),
  results: z.array(sendBatchResultOutputSchema),
})

const legacySendBatchOutputSchema = z.object({
  ok: z.boolean(),
  chatId: z.string().optional(),
  userId: z.string().optional(),
  stopOnError: z.boolean(),
  total: z.number(),
  sentCount: z.number(),
  failedCount: z.number(),
  results: z.array(
    z.object({
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
    }),
  ),
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
  nextOffsetId: z.string().nullable(),
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
  source: z.literal("messages"),
  messageIds: z.array(z.string()),
  includeUrlPreviews: z.boolean(),
  items: z.array(
    z.object({
      message: messageOutputSchema,
      files: z.array(fileItemOutputSchema),
    }),
  ),
})

const legacyFilesGetOutputSchema = z.object({
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
  contractVersion?: McpToolContract
}): McpServer {
  const resourceMetadataUrl = params.resourceMetadataUrl ?? DEFAULT_RESOURCE_METADATA_URL
  const contractVersion = params.contractVersion ?? "legacy"
  const submissionV2 = contractVersion === "submission-v2"
  const server = new McpServer(
    {
      name: "inline",
      version: submissionV2 ? "0.2.0" : "0.1.0",
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

  registerConversationMentions(server, { grant: params.grant, inline: params.inline, resourceMetadataUrl })

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
        destructiveHint: false,
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

  registerMessageResultsUi(server)

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
        limit: submissionV2
          ? z.number().int().min(1).max(50).optional().describe("Maximum spaces to return; defaults to 20")
          : z.number().int().min(1).max(50).default(20).describe("Maximum spaces to return"),
      },
      outputSchema: spacesListOutputSchema,
      annotations: {
        title: "List Spaces",
        readOnlyHint: true,
        destructiveHint: false,
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
        limit: submissionV2
          ? z.number().int().min(1).max(50).optional().describe("Maximum people to return; defaults to 20")
          : z.number().int().min(1).max(50).default(20).describe("Maximum people to return"),
      },
      outputSchema: peopleSearchOutputSchema,
      annotations: {
        title: "Search People",
        readOnlyHint: true,
        destructiveHint: false,
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
        limit: submissionV2
          ? z.number().int().min(1).max(50).optional().describe("Maximum conversations to return; defaults to 20")
          : z.number().int().min(1).max(50).default(20).describe("Maximum conversations to return"),
        unreadOnly: submissionV2
          ? z.boolean().optional().describe("Only include conversations with unread messages; defaults to false")
          : z.boolean().default(false).describe("Only include conversations with unread messages"),
        sort: z
          .enum(["relevance", "recent", "unread"])
          .optional()
          .describe("Sort mode. Defaults to `relevance` for queries and `recent` when listing without a query."),
      },
      outputSchema: conversationsListOutputSchema,
      annotations: {
        title: "List Conversations",
        readOnlyHint: true,
        destructiveHint: false,
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
      description: submissionV2
        ? "Use this tool after resolving a chatId to inspect conversation metadata, participants, pinned message IDs, and parent/thread details before reading or sending. DMs also use chatId."
        : "Use this tool after resolving a chatId or DM userId to inspect the conversation metadata, participants, pinned message IDs, and parent/thread details before reading or sending.",
      inputSchema: submissionV2
        ? {
            chatId: z.string().regex(/^[1-9]\d*$/).describe("Inline chat ID; required for every conversation, including DMs"),
          }
        : {
            chatId: z.string().min(1).optional().describe("Inline chat ID"),
            userId: z.string().min(1).optional().describe("Inline user ID (DM target)"),
          },
      outputSchema: conversationGetOutputSchema,
      annotations: {
        title: "Get Conversation",
        readOnlyHint: true,
        destructiveHint: false,
        openWorldHint: false,
      },
      _meta: toolMeta(["messages:read"], "Getting conversation...", "Conversation loaded"),
    },
    async ({ chatId, userId }: { chatId?: string; userId?: string }, extra: { authInfo?: AuthInfo }) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:read")

      const target = submissionV2
        ? { chatId: parseChatId(chatId!) }
        : parseTarget({ chatId, userId }, "conversations.get")
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
        "Use this tool to create a new Inline thread/chat in an allowed space or home threads. The audience follows the selected context: public threads in public spaces can be visible to anyone who joins. After creation, use messages.send or messages.send_batch with the returned chat.chatId.",
      inputSchema: {
        title: z.string().min(1).max(200).describe("Conversation title"),
        spaceId: z.string().min(1).optional().describe("Parent space ID for a thread"),
        description: z.string().max(1000).optional().describe("Optional description"),
        emoji: z.string().max(16).optional().describe("Optional emoji icon"),
        isPublic: submissionV2
          ? z.boolean().optional().describe("Whether the thread is visible to space members with public-thread access; defaults to false. In a public space, anyone permitted to join can see a public thread")
          : z.boolean().default(false).describe("Whether the thread is visible to space members with public-thread access. In a public space, anyone permitted to join can see a public thread"),
        participantUserIds: submissionV2
          ? z.array(z.string().min(1)).max(50).optional().describe("Participant user IDs for private chats; defaults to an empty list")
          : z.array(z.string().min(1)).max(50).default([]).describe("Participant user IDs (for private chats)"),
      },
      outputSchema: conversationCreatedOutputSchema,
      annotations: {
        title: "Create Conversation",
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: true,
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
      description: submissionV2
        ? "Use this tool to upload one base64 payload or public HTTPS URL before sending media. Set sourceType to describe the required source value. It returns an Inline media kind/id pair for messages.send_media or messages.send_batch."
        : "Use this tool to upload a local base64 payload or public HTTPS URL before sending media. It returns an Inline media kind/id pair for messages.send_media or messages.send_batch.",
      inputSchema: submissionV2
        ? {
            sourceType: z.enum(["base64", "url"]).describe("How to interpret source"),
            source: z.string().min(1).describe("Base64 payload or data URL when sourceType is base64; public HTTPS URL when sourceType is url"),
            kind: z.enum(["auto", "photo", "video", "document"]).optional().describe("Upload kind; defaults to auto, which infers photo, video, or document"),
            fileName: z.string().max(255).optional().describe("Optional file name override"),
            contentType: z.string().max(255).optional().describe("Optional content type override"),
            width: z.number().int().positive().optional().describe("Video width (video uploads only)"),
            height: z.number().int().positive().optional().describe("Video height (video uploads only)"),
            duration: z.number().int().positive().optional().describe("Video duration in seconds (video uploads only)"),
          }
        : {
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
        sourceType,
        source: sourceInput,
        base64,
        url,
        kind,
        fileName,
        contentType,
        width,
        height,
        duration,
      }: {
        sourceType?: "base64" | "url"
        source?: string
        base64?: string
        url?: string
        kind?: RequestedUploadKind
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

      const source = submissionV2
        ? await resolveUploadSource(sourceType === "base64" ? { base64: sourceInput } : { url: sourceInput })
        : await resolveUploadSource({ base64, url })
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
      description: submissionV2
        ? "Use this tool to extract file and media metadata from 1-20 known message IDs in one chat. Use messages.list with a files or media content filter first when message IDs are not known. DMs also use chatId."
        : "Use this tool to extract file/media metadata and URLs from specific message IDs, or from recent messages in one chat/DM when message IDs are not known.",
      inputSchema: submissionV2
        ? {
            chatId: z.string().regex(/^[1-9]\d*$/).describe("Inline chat ID; required for every conversation, including DMs"),
            messageIds: z.array(z.string().regex(/^[1-9]\d*$/)).min(1).max(20).describe("One to twenty message IDs from this chat to inspect"),
            includeUrlPreviews: z.boolean().optional().describe("Include media embedded in URL previews; defaults to true"),
          }
        : {
            chatId: z.string().min(1).optional().describe("Inline chat ID"),
            userId: z.string().min(1).optional().describe("Inline user ID (DM target)"),
            messageId: z.string().min(1).optional().describe("Single message ID to inspect"),
            messageIds: z.array(z.string().min(1)).max(20).optional().describe("Message IDs to inspect"),
            limit: z.number().int().min(1).max(50).default(20).describe("Recent messages to scan when no message IDs are provided"),
            includeUrlPreviews: z.boolean().default(true).describe("Include media embedded in URL previews"),
          },
      outputSchema: submissionV2 ? filesGetOutputSchema : legacyFilesGetOutputSchema,
      annotations: {
        title: "Get Files",
        readOnlyHint: true,
        destructiveHint: false,
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

      const target = submissionV2
        ? { chatId: parseChatId(chatId!) }
        : parseTarget({ chatId, userId }, "files.get")
      const ids = [...(messageId ? [messageId] : []), ...(messageIds ?? [])].map((id) => parseInlineId(id, "messageId"))
      if (ids.length > 20) throw new Error("messageIds length must be at most 20")
      const includePreviews = includeUrlPreviews !== false
      const result =
        submissionV2 || ids.length > 0
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
        source: submissionV2 || ids.length > 0 ? ("messages" as const) : ("recent" as const),
        messageIds: submissionV2 || ids.length > 0 ? ids.map((id) => id.toString()) : null,
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
      description: submissionV2
        ? "Use this tool to send an uploaded photo, video, or document to one chat. DMs also use chatId. Optional caption text is parsed as Inline Markdown. Delivery is recipient-visible and cannot be withdrawn through this tool. A public thread in a public space can be read by anyone permitted to join. Call files.upload first unless you already have an Inline media ID."
        : "Use this tool to send an uploaded photo, video, or document to one chat or DM. Optional caption text is parsed as Inline Markdown. Delivery is recipient-visible and cannot be withdrawn through this tool. A public thread in a public space can be read by anyone permitted to join. Call files.upload first unless you already have an Inline media ID.",
      inputSchema: submissionV2
        ? {
            chatId: z.string().regex(/^[1-9]\d*$/).describe("Inline chat ID; required for every conversation, including DMs"),
            mediaKind: z.enum(["photo", "video", "document"]).describe("Uploaded media kind"),
            mediaId: z.string().regex(/^[1-9]\d*$/).describe("Uploaded media ID"),
            text: z.string().max(8000).optional().describe(`Optional caption text. ${INLINE_MARKDOWN_HELP}`),
            replyToMsgId: z.string().regex(/^[1-9]\d*$/).optional().describe("Reply-to message ID"),
            sendMode: z.enum(["normal", "silent"]).optional().describe("Message delivery mode; defaults to normal"),
          }
        : {
            chatId: z.string().min(1).optional().describe("Inline chat ID"),
            userId: z.string().min(1).optional().describe("Inline user ID (DM target)"),
            mediaKind: z.enum(["photo", "video", "document"]).describe("Uploaded media kind"),
            mediaId: z.string().min(1).describe("Uploaded media ID"),
            text: z.string().max(8000).optional().describe(`Optional caption text. ${INLINE_MARKDOWN_HELP}`),
            replyToMsgId: z.string().min(1).optional().describe("Reply-to message ID"),
            sendMode: z.enum(["normal", "silent"]).default("normal").describe("Message delivery mode"),
          },
      outputSchema: submissionV2 ? sendMediaMessageOutputSchema : legacySendMediaMessageOutputSchema,
      annotations: {
        title: "Send Media Message",
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
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

      const target = submissionV2
        ? { chatId: parseChatId(chatId!) }
        : parseTarget({ chatId, userId }, "messages.send_media")
      const safeSendMode: "normal" | "silent" = sendMode === "silent" ? "silent" : "normal"
      const caption = text?.trim() ? text : undefined
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
      description: submissionV2
        ? "Use this tool to send an ordered sequence of normal, non-reply text and uploaded media items to one chat. DMs also use chatId. Text items are parsed as Inline Markdown. Every item has exactly two fields: type and content. Content is message text for type text, or an uploaded media ID for photo, video, and document. Use messages.send or messages.send_media instead when a reply target or silent delivery is needed. Delivered items are recipient-visible and cannot be withdrawn through this tool. A public thread in a public space can be read by anyone permitted to join."
        : "Use this tool to send an ordered sequence of text and uploaded media items to one chat or DM. Text and caption content is parsed as Inline Markdown. Delivered items are recipient-visible and cannot be withdrawn through this tool. A public thread in a public space can be read by anyone permitted to join. Prefer this over many separate sends when seeding a new thread or posting a multi-part update.",
      inputSchema: submissionV2
        ? {
            chatId: z.string().regex(/^[1-9]\d*$/).describe("Inline chat ID; required for every conversation, including DMs"),
            stopOnError: z.boolean().optional().describe("Stop sending after the first item error; defaults to false"),
            items: z
              .array(
                z.object({
                  type: z.enum(["text", "photo", "video", "document"]).describe("Content type"),
                  content: z
                    .string()
                    .min(1)
                    .max(8000)
                    .describe(`For type text: message text. ${INLINE_MARKDOWN_HELP} For photo, video, or document: uploaded Inline media ID, not Markdown.`),
                }).strict(),
              )
              .min(1)
              .max(100)
              .describe("One to one hundred ordered message items; every item requires type and content"),
          }
        : {
            chatId: z.string().min(1).optional().describe("Inline chat ID"),
            userId: z.string().min(1).optional().describe("Inline user ID (DM target)"),
            stopOnError: z.boolean().optional().describe("Stop sending after the first item error; defaults to false"),
            items: z
              .array(
                z.object({
                  type: z.enum(["text", "media"]).describe("Message item type"),
                  text: z.string().min(1).max(8000).optional().describe(`Required for text items; optional caption for media items. ${INLINE_MARKDOWN_HELP}`),
                  mediaKind: z.enum(["photo", "video", "document"]).optional().describe("Required for media items; omit for text items"),
                  mediaId: z.string().min(1).optional().describe("Required for media items; omit for text items"),
                  replyToMsgId: z.string().min(1).optional().describe("Optional message ID to reply to"),
                  sendMode: z.enum(["normal", "silent"]).optional().describe("Optional delivery mode; defaults to normal"),
                }),
              )
              .min(1)
              .max(100)
              .describe("Ordered list of message items. Text items require text. Media items require mediaKind and mediaId."),
          },
      outputSchema: submissionV2 ? sendBatchOutputSchema : legacySendBatchOutputSchema,
      annotations: {
        title: "Send Message Batch",
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
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
        items: Array<SendBatchItem | LegacySendBatchItem>
      },
      extra: { authInfo?: AuthInfo },
    ) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:write")

      const target = submissionV2
        ? { chatId: parseChatId(chatId!) }
        : parseTarget({ chatId, userId }, "messages.send_batch")
      const safeStopOnError = stopOnError === true
      const results: Array<Record<string, unknown>> = []
      let sentCount = 0
      let failedCount = 0

      for (let index = 0; index < items.length; index += 1) {
        const item = items[index]
        try {
          const legacyItem = submissionV2 ? undefined : (item as LegacySendBatchItem)
          const safeSendMode: SendMode = legacyItem?.sendMode === "silent" ? "silent" : "normal"
          const replyToMsgId = legacyItem?.replyToMsgId
          if (item.type === "text") {
            const itemText = submissionV2 ? (item as SendBatchItem).content : (item as LegacySendBatchItem).text
            if (!itemText) throw new Error(`items[${index}].text is required for text items`)
            const sent = await params.inline.sendMessage({
              ...target,
              text: itemText,
              ...(replyToMsgId ? { replyToMsgId: parseInlineId(replyToMsgId, "replyToMsgId") } : {}),
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
                ...(replyToMsgId ? { replyToMsgId } : {}),
              },
            })
            continue
          }

          const mediaKind = submissionV2
            ? (item as SendBatchItem).type as InlineUploadedMediaKind
            : (item as LegacySendBatchItem).mediaKind
          const mediaId = submissionV2 ? (item as SendBatchItem).content : (item as LegacySendBatchItem).mediaId
          if (!mediaKind) throw new Error(`items[${index}].mediaKind is required for media items`)
          if (!mediaId) throw new Error(`items[${index}].mediaId is required for media items`)
          const parsedMediaId = parseInlineId(mediaId, submissionV2 ? "content" : "mediaId")
          const caption = legacyItem?.text?.trim() ? legacyItem.text : undefined
          const sent = await params.inline.sendMediaMessage({
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
          sentCount += 1
          results.push({
            index,
            type: submissionV2 ? mediaKind : "media",
            status: "sent",
            messageId: sent.messageId?.toString() ?? null,
            media: {
              kind: mediaKind,
              id: parsedMediaId.toString(),
            },
            ...(caption ? { text: caption } : {}),
            metadata: {
              sendMode: safeSendMode,
              ...(replyToMsgId ? { replyToMsgId } : {}),
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
    "messages.view",
    {
      title: "View Inline Sources or Catch Up",
      description: "Display original Inline evidence or browse actual conversation history only when requested or useful. For ordinary summaries or analysis, use the data-only messages.list/search/context tools and report actual coverage. sources accepts 1–20 ordered canonical message references from any allowed chats; it does not imply contiguous history. catch_up accepts 1–20 chat IDs and reads only the active chat's bounded history, without marking read. Use exactly one of startAt (latest or unread), offsetId (older), afterId (newer), or anchorMessageId (surrounding context); unread entry may show history since last read when an exact first-unread location cannot be verified. Never supply authored message text, names, quotations, URLs, or analyzed counts.",
      inputSchema: {
        presentation: z.enum(["sources", "catch_up"]),
        items: z.array(z.object({ chatId: z.string().regex(/^[1-9]\d*$/).max(20), messageId: z.string().regex(/^[1-9]\d*$/).max(20) }).strict()).min(1).max(20).optional(),
        chatIds: z.array(z.string().regex(/^[1-9]\d*$/).max(20)).min(1).max(20).optional(),
        activeChatId: z.string().regex(/^[1-9]\d*$/).max(20).optional(),
        startAt: z.enum(["latest", "unread"]).optional(),
        offsetId: z.string().regex(/^[1-9]\d*$/).max(20).optional(),
        afterId: z.string().regex(/^[1-9]\d*$/).max(20).optional(),
        anchorMessageId: z.string().regex(/^[1-9]\d*$/).max(20).optional(),
      },
      outputSchema: messageViewOutputSchema,
      annotations: { readOnlyHint: true, openWorldHint: false, destructiveHint: false },
      _meta: {
        ...toolMeta(["messages:read"], "Loading Inline originals...", "Inline originals loaded"),
        ui: { resourceUri: MESSAGE_RESULTS_RESOURCE_URI, visibility: ["model", "app"] },
      },
    },
    async (args: {
      presentation: "sources" | "catch_up"; items?: Array<{ chatId: string; messageId: string }>; chatIds?: string[];
      activeChatId?: string; startAt?: "latest" | "unread"; offsetId?: string; afterId?: string; anchorMessageId?: string;
    }, extra) => {
      const auth = presentationReadAuth(params.grant, extra.authInfo)
      const cursors = [args.startAt, args.offsetId, args.afterId, args.anchorMessageId].filter((value) => value != null)
      if (args.presentation === "sources" && (!args.items?.length || args.chatIds != null || args.activeChatId != null || cursors.length)) {
        throw new Error("sources requires only ordered items; catch-up parameters are not accepted")
      }
      if (args.presentation === "catch_up" && (!args.chatIds?.length || args.items != null || cursors.length > 1)) {
        throw new Error("catch_up requires chatIds and at most one history cursor")
      }
      const refs = [...new Map((args.items ?? []).map((item) => [`${item.chatId}:${item.messageId}`, item])).values()]
      const chatIds = [...new Set(args.presentation === "sources" ? refs.map((ref) => ref.chatId) : args.chatIds)]
      if (args.activeChatId && !chatIds.includes(args.activeChatId)) throw new Error("activeChatId must belong to chatIds")
      const metadata = await presentationMap(chatIds, async (chatId) => {
        try {
          const result = await params.inline.presentationChat({ chatId: parseChatId(chatId), includeLastMessage: args.presentation === "catch_up" })
          if (result.chat.chatId.toString() !== chatId || !presentationChatAllowed(result.chat, params.grant, auth)) return null
          return result
        } catch { return null }
      })
      const chatAvatarUrls: Record<string, string> = {}
      const chats = chatIds.map((chatId, index) => {
        const result = metadata[index]
        const avatar = signedPresentationUrl(result?.chatAvatarUrl)
        if (avatar) chatAvatarUrls[chatId] = avatar
        return { chatId, status: result ? "available" as const : "unavailable" as const,
          chat: result ? { ...chatMetadata(result.chat), title: presentationString(result.chat.title, 512), chatTitle: presentationString(result.chat.chatTitle, 512),
            lastMessagePreview: snippetOf(result.lastMessage?.message, 120) ?? null } : null }
      })
      const senderAvatarUrls: Record<string, string> = {}
      const messageMedia: Record<string, { thumbnailUrl: string | null; originalUrl: string | null; originalFileUniqueId?: string }> = {}
      const row = (message: Message, result: InlineMessagesResult) => {
        const key = `${message.chatId}:${message.id}`
        const media = presentationMedia(message)
        if (media.thumbnailUrl || media.originalUrl) messageMedia[key] = media
        const senderId = message.fromId?.toString()
        const avatar = senderId ? signedPresentationUrl(result.senderAvatarUrls?.[senderId]) : null
        if (senderId && avatar) senderAvatarUrls[senderId] = avatar
        return { chatId: message.chatId.toString(), messageId: message.id.toString(), status: "available" as const, message: presentationMessage(message, result) }
      }
      const unavailable = (ref: { chatId: string; messageId: string }) => ({ ...ref, status: "unavailable" as const, message: null })
      let items: Array<ReturnType<typeof row> | ReturnType<typeof unavailable>> = []
      let activeChatId: string | null = null
      let page: z.infer<typeof messageViewOutputSchema>["page"] = {
        kind: "selected", nextOffsetId: null, nextAfterId: null, anchorMessageId: null, firstUnreadMessageId: null,
        note: "Selected original messages in the requested order; this selection does not establish continuous history or analyzed coverage.",
      }
      if (args.presentation === "sources") {
        const fetched = await presentationMap(chatIds, async (chatId) => {
          if (!metadata[chatIds.indexOf(chatId)]) return null
          try {
            const result = await params.inline.getMessages({ chatId: parseChatId(chatId), messageIds: refs.filter((ref) => ref.chatId === chatId).map((ref) => parseInlineId(ref.messageId, "messageId")), freshChatAuthorization: true })
            return result.chat.chatId.toString() === chatId && presentationChatAllowed(result.chat, params.grant, auth) ? result : null
          } catch { return null }
        })
        items = refs.map((ref) => {
          const result = fetched[chatIds.indexOf(ref.chatId)]
          const message = result?.messages.find((message) => message.chatId.toString() === ref.chatId && message.id.toString() === ref.messageId)
          return result && message ? row(message, result) : unavailable(ref)
        })
        // An access change between metadata and source reads clears that chat's
        // title/avatar too; stale discovery must never reveal a denied target.
        chats.forEach((chat, index) => {
          if (!fetched[index]) { chat.status = "unavailable"; chat.chat = null; delete chatAvatarUrls[chat.chatId] }
        })
      } else {
        activeChatId = args.activeChatId ?? chats.find((chat) => chat.status === "available")?.chatId ?? chatIds[0] ?? null
        page = { ...page, kind: "latest", note: "The selected conversation is unavailable. No message history was returned." }
        if (activeChatId && metadata[chatIds.indexOf(activeChatId)]) {
          try {
            const history = await params.inline.historyMessages({ chatId: parseChatId(activeChatId),
              ...(args.startAt ? { startAt: args.startAt } : {}), ...(args.offsetId ? { offsetId: parseInlineId(args.offsetId, "offsetId") } : {}),
              ...(args.afterId ? { afterId: parseInlineId(args.afterId, "afterId") } : {}), ...(args.anchorMessageId ? { anchorMessageId: parseInlineId(args.anchorMessageId, "anchorMessageId") } : {}),
            })
            if (history.chat.chatId.toString() !== activeChatId || !presentationChatAllowed(history.chat, params.grant, auth)) throw new Error("Conversation is no longer in the allowed context")
            items = history.messages.filter((message) => message.chatId.toString() === activeChatId).slice(0, 50).map((message) => row(message, history))
            const active = chats.find((chat) => chat.chatId === activeChatId)!
            active.chat = { ...chatMetadata(history.chat), lastMessagePreview: active.chat?.lastMessagePreview ?? null }
            page = { kind: history.kind, nextOffsetId: history.nextOffsetId?.toString() ?? null, nextAfterId: history.nextAfterId?.toString() ?? null,
              anchorMessageId: history.anchorMessageId?.toString() ?? null, firstUnreadMessageId: history.firstUnreadMessageId?.toString() ?? null, note: history.note }
          } catch {
            const active = chats.find((chat) => chat.chatId === activeChatId)!
            active.status = "unavailable"; active.chat = null; delete chatAvatarUrls[activeChatId]
          }
        }
      }
      if (items.some((item) => item.message?.textTruncated)) page.note = [page.note, "Long messages are shortened in this view. Ask ChatGPT for the complete message."].filter(Boolean).join(" ")
      const payload = { presentation: args.presentation, chats, items, activeChatId, page }
      if (Buffer.byteLength(JSON.stringify(payload)) > 512 * 1024) throw new Error("The bounded presentation payload is too large; request fewer messages")
      return { structuredContent: payload, content: [jsonText(payload)], _meta: { inline: { senderAvatarUrls, chatAvatarUrls, messageMedia } } }
    },
  )

  registerInlineTool(
    server,
    resourceMetadataUrl,
    "messages.list",
    {
      title: "List Inline Messages",
      description: submissionV2
        ? "Use this tool to read recent context from one resolved chatId for summarization, answering questions, or preparing a reply. DMs also use chatId. Supports time windows like today, yesterday, 2d ago, YYYY-MM-DD, or epoch seconds."
        : "Use this tool to read recent context from one resolved chatId or DM userId for summarization, answering questions, or preparing a reply. Supports time windows like today, yesterday, 2d ago, YYYY-MM-DD, or epoch seconds.",
      inputSchema: submissionV2
        ? {
            chatId: z.string().regex(/^[1-9]\d*$/).describe("Inline chat ID; required for every conversation, including DMs"),
            limit: z.number().int().min(1).max(50).optional().describe("Maximum messages to return; defaults to 20"),
            offsetId: z.string().regex(/^[1-9]\d*$/).optional().describe("Fetch messages older than this message ID"),
            since: z.string().min(1).optional().describe("Lower time bound (e.g. yesterday, 2d ago, 2026-02-20)"),
            until: z.string().min(1).optional().describe("Upper time bound"),
            content: z.enum(["all", "links", "media", "photos", "videos", "documents", "files"]).optional().describe("Content type filter; defaults to all"),
          }
        : {
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
        destructiveHint: false,
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

      const target = submissionV2
        ? { chatId: parseChatId(chatId!) }
        : parseTarget({ chatId, userId }, "messages.list")
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
      const messages = recent.messages.map((message) => namedMessagePayload(message, recent.senderDisplayNames))

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
      description: submissionV2
        ? "Use this tool after messages.search, messages.unread, or a known message ID to fetch a before/after window around that message in one chat. DMs also use chatId. Use messages.list for the latest context when there is no anchor message."
        : "Use this tool after messages.search, messages.unread, or a known message ID to fetch a before/after window around that message. Omit anchorMessageId to get a compact latest context window.",
      inputSchema: submissionV2
        ? {
            chatId: z.string().regex(/^[1-9]\d*$/).describe("Inline chat ID; required for every conversation, including DMs"),
            anchorMessageId: z.string().regex(/^[1-9]\d*$/).describe("Message ID to center the context window around"),
            before: z.number().int().min(0).max(50).optional().describe("Messages before/older than the anchor; defaults to 8"),
            after: z.number().int().min(0).max(50).optional().describe("Messages after/newer than the anchor; defaults to 8"),
            includeAnchor: z.boolean().optional().describe("Include the anchor message; defaults to true"),
            content: z.enum(["all", "links", "media", "photos", "videos", "documents", "files"]).optional().describe("Content type filter; defaults to all"),
          }
        : {
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
        destructiveHint: false,
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

      const target = submissionV2
        ? { chatId: parseChatId(chatId!) }
        : parseTarget({ chatId, userId }, "messages.context")
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
      description: submissionV2
        ? "Use this tool to search for required text within one resolved chatId. DMs also use chatId. Use conversations.list first when the target is unclear, or messages.list when filtering only by time/content without search text."
        : "Use this tool to search within one resolved chatId or DM userId. This is intentionally scoped to a single conversation; use conversations.list first when the target is unclear.",
      inputSchema: submissionV2
        ? {
            chatId: z.string().regex(/^[1-9]\d*$/).describe("Inline chat ID; required for every conversation, including DMs"),
            query: z.string().min(1).describe("Text to search for in this conversation"),
            offsetId: z.string().regex(/^[1-9]\d*$/).optional().describe("Continue matches older than the previous nextOffsetId"),
            limit: z.number().int().min(1).max(50).optional().describe("Maximum messages to return; defaults to 20"),
            since: z.string().min(1).optional().describe("Lower time bound"),
            until: z.string().min(1).optional().describe("Upper time bound"),
            content: z.enum(["all", "links", "media", "photos", "videos", "documents", "files"]).optional().describe("Content type filter; defaults to all"),
          }
        : {
            chatId: z.string().min(1).optional().describe("Inline chat ID"),
            userId: z.string().min(1).optional().describe("Inline user ID (DM target)"),
            query: z.string().min(1).optional().describe("Optional search query"),
            offsetId: z.string().min(1).optional().describe("Continue matches older than the previous nextOffsetId"),
            limit: z.number().int().min(1).max(50).default(20).describe("Maximum messages to return"),
            since: z.string().min(1).optional().describe("Lower time bound"),
            until: z.string().min(1).optional().describe("Upper time bound"),
            content: z.enum(["all", "links", "media", "photos", "videos", "documents", "files"]).default("all").describe("Content type filter"),
          },
      outputSchema: messagesSearchOutputSchema,
      annotations: {
        title: "Search Messages",
        readOnlyHint: true,
        destructiveHint: false,
        openWorldHint: false,
      },
      _meta: toolMeta(["messages:read"], "Searching messages in chat...", "Message search complete"),
    },
    async (
      {
        chatId,
        userId,
        query,
        offsetId,
        limit,
        since,
        until,
        content,
      }: {
        chatId?: string
        userId?: string
        query?: string
        offsetId?: string
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

      const target = submissionV2
        ? { chatId: parseChatId(chatId!) }
        : parseTarget({ chatId, userId }, "messages.search")
      const parsedSince = parseTimeInput(since, "since")
      const parsedUntil = parseTimeInput(until, "until")
      const safeContent = parseContentFilter(content)
      const found: InlineSearchMessagesResult = await params.inline.searchMessages({
        ...target,
        query,
        offsetId: offsetId ? parseInlineId(offsetId, "offsetId") : undefined,
        limit: limit ?? 20,
        since: parsedSince,
        until: parsedUntil,
        content: safeContent,
      })

      const messages = found.messages.map((message) => namedMessagePayload(message, found.senderDisplayNames))

      const payload = {
        query: found.query,
        nextOffsetId: found.nextOffsetId?.toString() ?? null,
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
        limit: submissionV2
          ? z.number().int().min(1).max(200).optional().describe("Maximum unread messages to return; defaults to 50")
          : z.number().int().min(1).max(200).default(50).describe("Maximum unread messages to return"),
        since: z.string().min(1).optional().describe("Lower time bound"),
        until: z.string().min(1).optional().describe("Upper time bound"),
        content: submissionV2
          ? z.enum(["all", "links", "media", "photos", "videos", "documents", "files"]).optional().describe("Content type filter; defaults to all")
          : z.enum(["all", "links", "media", "photos", "videos", "documents", "files"]).default("all").describe("Content type filter"),
      },
      outputSchema: messagesUnreadOutputSchema,
      annotations: {
        title: "Unread Messages",
        readOnlyHint: true,
        destructiveHint: false,
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
      description: submissionV2
        ? "Use this tool to send one recipient-visible text message to one resolved chatId; DMs also use chatId. Text is parsed as Inline Markdown. It cannot be withdrawn through this tool. A public thread in a public space can be read by anyone permitted to join. Use conversations.list first when resolving a person, DM, thread, or space chat."
        : "Use this tool to send one recipient-visible text message after the target is clear; text is parsed as Inline Markdown and the message cannot be withdrawn through this tool. A public thread in a public space can be read by anyone permitted to join. Provide exactly one of chatId or userId; use conversations.list first when resolving a person, DM, thread, or space chat.",
      inputSchema: submissionV2
        ? {
            chatId: z.string().regex(/^[1-9]\d*$/).describe("Inline chat ID; required for every conversation, including DMs"),
            text: z.string().min(1).max(8000).describe(`Message text. ${INLINE_MARKDOWN_HELP}`),
            replyToMsgId: z.string().regex(/^[1-9]\d*$/).optional().describe("Reply-to message ID"),
            sendMode: z.enum(["normal", "silent"]).optional().describe("Message delivery mode; defaults to normal"),
          }
        : {
            chatId: z.string().min(1).optional().describe("Inline chat ID"),
            userId: z.string().min(1).optional().describe("Inline user ID (DM target)"),
            text: z.string().min(1).max(8000).describe(`Message text. ${INLINE_MARKDOWN_HELP}`),
            replyToMsgId: z.string().min(1).optional().describe("Reply-to message ID"),
            sendMode: z.enum(["normal", "silent"]).default("normal").describe("Message delivery mode"),
          },
      outputSchema: submissionV2 ? sendMessageOutputSchema : legacySendMessageOutputSchema,
      annotations: {
        title: "Send Message",
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
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

        const target = submissionV2
          ? { chatId: parseChatId(chatId!) }
          : parseTarget({ chatId, userId }, "messages.send")
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
