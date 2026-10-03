import { Buffer } from "node:buffer"
import { lookup } from "node:dns/promises"
import { request as httpsRequest } from "node:https"
import { BlockList, isIP } from "node:net"
import * as z from "zod/v4"
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { AuthInfo } from "@modelcontextprotocol/sdk/server/auth/types.js"
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import type { McpGrant } from "./grant"
import { MessageEntity_Type, RpcError_Code, type Message, type UrlPreview } from "@inline-chat/protocol/core"
import { InlineSdkAuthenticationError, ProtocolClientError } from "@inline-chat/realtime-sdk"
import { InlineAccessDeniedError } from "../inline/inline-api"
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
import { MESSAGE_RESULTS_RESOURCE_URI, registerMessageResultsUi } from "./message-results-ui"
import { registerConversationMentions } from "./conversation-mentions"
import type { EventsProxy } from "./events-proxy"
import { THREAD_RESOURCE_URI, registerThreadUi } from "./thread-ui"

const MAX_UPLOAD_BYTES = 25 * 1024 * 1024
const MAX_UPLOAD_REDIRECTS = 3
const UPLOAD_DNS_TIMEOUT_MS = 5_000
const UPLOAD_FETCH_TIMEOUT_MS = 15_000
const SUPPORTED_PHOTO_MIME = new Set(["image/jpeg", "image/png", "image/gif", "image/webp"])
const SUPPORTED_VIDEO_MIME = new Set(["video/mp4"])
const DEFAULT_RESOURCE_METADATA_URL = "https://mcp.inline.chat/.well-known/oauth-protected-resource"
export const INLINE_MCP_INSTRUCTIONS =
  "Inline MCP gives scoped access to the user's work chats. Resolve people, spaces, or thread names with people.search, spaces.list, and conversations.list before using chatId; inspect a target with conversations.get; read context with messages.get/list/search/context/unread; send only after the target is clear. Address requested recipients by name using [@Name](inline://user?id=USER_ID) with their resolved user IDs; plain names are not mentions. For forwarding, resolve the source and destination separately, select source messages, then use messages.forward. Subthreads inherit root-chat access plus their own direct/group grants; participants added only to an intermediate child are not automatically inherited by descendants. Creation inputs do not edit existing anchored reply threads. IDs are positive decimal strings. Time filters accept today, yesterday, 2d ago, YYYY-MM-DD, or epoch seconds; calendar days use UTC. Use account.me to inspect scopes and allowed chat contexts."

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
type ConversationSort = "relevance" | "recent" | "unread" | "id"

export type McpToolContract = "legacy" | "submission-v2"

export function inlineMcpInstructions(contractVersion: McpToolContract): string {
  return INLINE_MCP_INSTRUCTIONS + (contractVersion === "submission-v2"
    ? " For teammate input, resolve the people and context first. Before sending an ask-and-wait request, establish that the originating host can subscribe and resume this task. OpenAI supports this in Work chats (Cloud on desktop) and dots, not regular ChatGPT chats. Server Events availability alone does not prove host continuation support. Explain an unsupported host before sending; proceed only if sending without automatic continuation satisfies the user. conversations.ask creates a private thread, mentions the recipients, sends one question and returns a message.created subscription selector and replay cursor. It does not itself subscribe or wait. Subscribe using events/subscribe from that cursor before waiting; monitoring starts only after subscription acknowledgement. On an event, read current message context and continue the originating task. Never repeat an uncertain write automatically. conversations.open opens the minimal Inline thread UI; its picker only remembers threads explicitly opened in this ChatGPT experience."
    : "")
}

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
  if (error instanceof InsufficientScopeError || error instanceof InlineAccessDeniedError || error instanceof InlineSdkAuthenticationError ||
    (error instanceof ProtocolClientError && error.code === "rpc-error" && error.rpcCode !== undefined &&
      [RpcError_Code.UNAUTHENTICATED, RpcError_Code.PEER_ID_INVALID, RpcError_Code.CHAT_ID_INVALID, RpcError_Code.SPACE_ID_INVALID].includes(error.rpcCode))) {
    result._meta = { ...result._meta, inline: { accessDenied: true } }
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
    if (!/^[1-9]\d*$/.test(input)) throw new Error(`invalid ${field}`)
    const id = BigInt(input)
    if (id > 9_223_372_036_854_775_807n) throw new Error(`invalid ${field}`)
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

function startOfUtcDay(date: Date): Date {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate(), 0, 0, 0, 0))
}

function endOfUtcDay(date: Date): Date {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate(), 23, 59, 59, 999))
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
    const date = kind === "since" ? startOfUtcDay(now) : endOfUtcDay(now)
    return BigInt(Math.floor(date.getTime() / 1000))
  }
  if (value === "yesterday") {
    const base = new Date(now)
    base.setUTCDate(base.getUTCDate() - 1)
    const date = kind === "since" ? startOfUtcDay(base) : endOfUtcDay(base)
    return BigInt(Math.floor(date.getTime() / 1000))
  }

  const relative = parseRelativeAgo(value)
  if (relative != null) return relative

  const integerSeconds = parseIntegerSeconds(value)
  if (integerSeconds != null) {
    if (integerSeconds > 9_223_372_036_854_775_807n) throw new Error(`invalid ${kind} value: epoch seconds exceed the protocol range`)
    return integerSeconds
  }

  const dayOnlyMatch = value.match(/^(\d{4})-(\d{2})-(\d{2})$/)
  if (dayOnlyMatch) {
    const year = Number(dayOnlyMatch[1])
    const month = Number(dayOnlyMatch[2]) - 1
    const day = Number(dayOnlyMatch[3])
    const date = new Date(Date.UTC(year, month, day, 0, 0, 0, 0))
    if (date.getUTCFullYear() === year && date.getUTCMonth() === month && date.getUTCDate() === day) {
      if (kind === "until") date.setUTCHours(23, 59, 59, 999)
      return BigInt(Math.floor(date.getTime() / 1000))
    }
    throw new Error(`invalid ${kind} value: calendar date does not exist`)
  }

  const timestampDatePrefix = value.match(/^(\d{4})-(\d{2})-(\d{2})/)
  if (timestampDatePrefix) {
    const year = Number(timestampDatePrefix[1])
    const month = Number(timestampDatePrefix[2]) - 1
    const day = Number(timestampDatePrefix[3])
    // Date parsing normalizes impossible days even in ISO timestamps. Validate
    // the written calendar date before its explicit offset shifts the instant.
    const calendarDate = new Date(0)
    calendarDate.setUTCFullYear(year, month, day)
    if (calendarDate.getUTCFullYear() !== year || calendarDate.getUTCMonth() !== month || calendarDate.getUTCDate() !== day) {
      throw new Error(`invalid ${kind} value: calendar date does not exist`)
    }
  }

  const parsed = new Date(value)
  if (!Number.isNaN(parsed.getTime())) {
    return BigInt(Math.floor(parsed.getTime() / 1000))
  }

  throw new Error(`invalid ${kind} value`)
}

function parseTimeRange(since?: string, until?: string): { parsedSince?: bigint; parsedUntil?: bigint } {
  const parsedSince = parseTimeInput(since, "since")
  const parsedUntil = parseTimeInput(until, "until")
  if (parsedSince != null && parsedUntil != null && parsedSince > parsedUntil) {
    throw new Error("since must be earlier than or equal to until")
  }
  return { parsedSince, parsedUntil }
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
    case "id":
      return "id"
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
    out.push(parseInlineId(value, field))
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
  if (sort === "id") return copy.sort((left, right) => left.chatId === right.chatId ? 0 : left.chatId < right.chatId ? -1 : 1)
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
  sort: z.enum(["relevance", "recent", "unread", "id"]),
  bestMatch: conversationListItemOutputSchema.nullable(),
  unreadOnly: z.boolean(),
  spaceId: z.string().nullable(),
  kind: z.enum(["dm", "home_thread", "space_chat"]).nullable(),
  items: z.array(conversationListItemOutputSchema),
  nextAfterChatId: z.string().nullable(),
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
    groupParticipantCount: z.number().int().nonnegative().describe("Number of explicit group grants on this chat, not group-member or effective-audience count"),
  }),
  participants: z.array(personOutputSchema).describe("Direct user participants only; group members and inherited root-chat access are not enumerated"),
})

const conversationCreatedOutputSchema = z.object({
  chat: chatMetadataOutputSchema,
})

const conversationOpenOutputSchema = conversationGetOutputSchema.extend({
  chat: chatMetadataOutputSchema.nullable(),
  details: conversationGetOutputSchema.shape.details.nullable(),
  messages: z.array(messageOutputSchema).max(50),
  nextOffsetId: z.string().nullable(),
  capabilities: z.object({ canSend: z.boolean() }),
  monitoring: z.object({ active: z.boolean(), expiresAt: z.string().optional() }).optional(),
})

const conversationAskOutputSchema = z.object({
  chat: chatMetadataOutputSchema,
  questionStatus: z.enum(["sent", "not_sent", "unknown"]),
  messageId: z.string().nullable(),
  event: z.object({
    name: z.literal("message.created"),
    arguments: z.object({ chatId: z.string(), excludeSelf: z.literal(true) }),
    cursor: z.string(),
  }).nullable(),
  nextStep: z.string(),
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
  scannedCount: z.number().describe("History messages examined before sender/time/content filters; at most 500 per call"),
  senderUserId: z.string().nullable(),
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
  nextOffsetId: z.string().nullable(),
  scannedCount: z.number().describe("Server search matches examined before sender/time filters; excludes the server's underlying text scan"),
  senderUserId: z.string().nullable(),
  messages: z.array(messageOutputSchema),
})

const messagesGetOutputSchema = z.object({
  chat: chatMetadataOutputSchema,
  messageIds: z.array(z.string()),
  missingMessageIds: z.array(z.string()),
  messages: z.array(messageOutputSchema),
})

const subthreadCreatedOutputSchema = z.object({
  chat: chatMetadataOutputSchema,
  parentChatId: z.string(),
  parentMessageId: z.string().nullable(),
  anchorMessageId: z.string().nullable(),
})

const messagesForwardOutputSchema = z.object({
  ok: z.literal(true),
  sourceChat: chatMetadataOutputSchema,
  destinationChat: chatMetadataOutputSchema,
  messages: z.array(z.object({ sourceMessageId: z.string(), destinationMessageId: z.string(), uri: z.string() })),
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
  events?: (auth: AuthInfo) => EventsProxy
}): McpServer {
  const resourceMetadataUrl = params.resourceMetadataUrl ?? DEFAULT_RESOURCE_METADATA_URL
  const contractVersion = params.contractVersion ?? "legacy"
  const submissionV2 = contractVersion === "submission-v2"
  const server = new McpServer(
    {
      name: "inline",
      version: submissionV2 ? "0.3.0" : "0.1.0",
      title: "Inline",
      description: "Scoped access to Inline work chats for thread-first agents.",
      websiteUrl: "https://inline.chat",
    },
    {
      capabilities: {
        tools: { listChanged: false },
      },
      instructions: inlineMcpInstructions(contractVersion),
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
          "Message reads require messages:read; space listing requires spaces:read; people search requires both read scopes; creation, sends, and uploads require messages:write; forwarding requires messages:read and messages:write.",
        ],
      }
      return {
        structuredContent: payload,
        content: [jsonText(payload)],
      }
    },
  )

  registerMessageResultsUi(server)

  if (submissionV2) {
    registerThreadUi(server)
    registerInlineTool(server, resourceMetadataUrl, "conversations.open", {
      title: "Inline Threads",
      description: "Open one resolved Inline thread with recent history, direct participants and a composer. Omit chatId to open the minimal picker of threads already viewed in this ChatGPT app; this does not list your workspace. Monitoring is reported only when the Events service confirms an active message subscription for this grant.",
      inputSchema: { chatId: z.string().regex(/^[1-9]\d*$/).optional().describe("Resolved Inline chat ID; omit for the small thread picker") },
      outputSchema: conversationOpenOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
      _meta: {
        ...toolMeta(["messages:read"], "Opening Inline thread...", "Inline thread opened"),
        ui: { resourceUri: THREAD_RESOURCE_URI, visibility: ["model", "app"] },
        "openai/ui": { entrypoints: [{ type: "thread" }, { type: "global" }] },
      },
    }, async ({ chatId }: { chatId?: string }, extra) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:read")
      const capabilities = { canSend: scopes.includes("messages:write") }
      if (!chatId) {
        const payload = { chat: null, details: null, participants: [], messages: [], nextOffsetId: null, capabilities }
        return { structuredContent: payload, content: [jsonText(payload)] }
      }
      const target = { chatId: parseChatId(chatId) }
      const details = await params.inline.getConversation(target)
      const history = await params.inline.recentMessages({ ...target, limit: 50, freshChatAuthorization: true })
      let monitoring: { active: boolean; expiresAt?: string } | undefined
      if (auth && params.events) {
        try {
          const result = await params.events(auth).request("events/status", { chatId })
          const subscriptions = Array.isArray(result.subscriptions) ? result.subscriptions : []
          const expiries = subscriptions.flatMap((value: unknown) => {
            if (!value || typeof value !== "object") return []
            const entry = value as Record<string, unknown>
            if (entry.name !== "message.created" || typeof entry.refreshBefore !== "string") return []
            const expiresAt = Date.parse(entry.refreshBefore)
            return Number.isFinite(expiresAt) && expiresAt > Date.now() ? [entry.refreshBefore] : []
          }).sort()
          monitoring = { active: expiries.length > 0, ...(expiries[0] ? { expiresAt: expiries[0] } : {}) }
        } catch { /* Reading a thread stays useful if monitoring status is temporarily unavailable. */ }
      }
      const payload = {
        ...conversationDetailsPayload(details),
        messages: history.messages.map((message) => namedMessagePayload(message, history.senderDisplayNames)),
        nextOffsetId: history.nextOffsetId?.toString() ?? null,
        capabilities,
        ...(monitoring ? { monitoring } : {}),
      }
      return { structuredContent: payload, content: [jsonText(payload)] }
    })

    registerInlineTool(server, resourceMetadataUrl, "conversations.ask", {
      title: "Ask Inline Teammates",
      description: "Create a private Inline thread containing you and the resolved participants, address them with named mentions, send one question, and return a replay cursor. This tool does not subscribe or wait. For ask-and-wait requests, first establish that the originating host can subscribe and resume (ChatGPT Work or dots). Regular ChatGPT chats cannot automatically resume; explain that before sending and only proceed if a send without automatic continuation satisfies the user. Subscribe to the returned message.created event with events/subscribe, using its exact arguments and cursor; then wait and resume the originating task when a reply arrives. Creation and delivery are not idempotent: retain a confirmed chat ID and inspect any uncertain outcome before retrying. Monitoring is not active until the host acknowledges a subscription.",
      inputSchema: {
        title: z.string().trim().min(1).max(200),
        question: z.string().trim().min(1).max(8000).describe(`Question delivered to the participants; Inline prepends a named mention of each resolved recipient. ${INLINE_MARKDOWN_HELP}`),
        participantUserIds: z.array(z.string().regex(/^[1-9]\d*$/)).min(1).max(10).describe("Resolved teammate or existing Inline agent user IDs; the connected user is added automatically"),
        spaceId: z.string().regex(/^[1-9]\d*$/).optional().describe("Authorized parent space; omit for an authorized home thread"),
      },
      outputSchema: conversationAskOutputSchema,
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true },
      _meta: {
        ...toolMeta(["messages:read", "messages:write"], "Asking Inline teammates...", "Inline question prepared"),
        ui: { resourceUri: THREAD_RESOURCE_URI, visibility: ["model", "app"] },
      },
    }, async (args: { title: string; question: string; participantUserIds: string[]; spaceId?: string }, extra) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:read")
      requireScope(scopes, "messages:write")
      if (!auth || !params.events) throw new Error("Inline Events is unavailable; the question was not sent.")
      const participants = [...new Set(args.participantUserIds.map((id) => parseUserId(id)))].filter((id) => id !== params.grant.inlineUserId)
      if (!participants.length) throw new Error("Choose at least one teammate other than yourself.")
      // Resolve exact identities before any write. A display name is data, so
      // escape it before composing Markdown; do not accept fuzzy ID matches.
      const recipients = await Promise.all(participants.map(async (userId) => {
        const result = await params.inline.searchPeople({ query: userId.toString(), limit: 50 })
        const person = result.items.find((candidate) => candidate.userId === userId)
        if (!person?.displayName.trim()) throw new Error("A participant could not be resolved. Resolve the requested people before creating the thread; nothing was sent.")
        const label = person.displayName.replace(/\s+/g, " ").trim().replace(/[!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~]/g, "\\$&")
        return `[@${label}](inline://user?id=${userId})`
      }))
      const question = `${recipients.join(" ")}\n\n${args.question}`
      if (question.length > 8000) throw new Error("Shorten the question to leave room for recipient mentions; nothing was sent.")
      const spaceId = args.spaceId ? parseInlineId(args.spaceId, "spaceId") : undefined
      const events = params.events(auth)
      await events.request("events/list", {}) // Confirm Events before creating anything.
      let created: InlineEligibleChat
      try {
        created = await params.inline.createChat({ title: args.title, isPublic: false, participantUserIds: participants, ...(spaceId ? { spaceId } : {}) })
      } catch {
        throw new Error("Inline could not confirm thread creation. Inspect recent conversations before retrying; an uncertain write may already have created the thread.")
      }
      const chat = chatMetadata(created)
      const selector = { chatId: created.chatId.toString(), excludeSelf: true as const }
      const result = (questionStatus: "sent" | "not_sent" | "unknown", messageId: string | null,
        event: { name: "message.created"; arguments: typeof selector; cursor: string } | null, nextStep: string): CallToolResult => {
        const payload = { chat, questionStatus, messageId, event, nextStep }
        return { ...(questionStatus === "sent" ? {} : { isError: true }), structuredContent: payload, content: [jsonText(payload)] }
      }
      let cursor: string
      try {
        const checkpoint = await events.request("events/cursor", { name: "message.created", arguments: selector })
        if (typeof checkpoint.cursor !== "string" || !checkpoint.cursor) throw new Error("Missing event cursor")
        cursor = checkpoint.cursor
      } catch {
        return result("not_sent", null, null, "The private thread exists, but the question was not sent. Reuse this chatId. If the host supports continuation, activate a message.created subscription before using messages.send; otherwise disclose the limitation and send only if the user accepts sending without automatic continuation. Do not create another thread.")
      }
      const event = { name: "message.created" as const, arguments: selector, cursor }
      try {
        const receipt = await params.inline.sendMessage({ chatId: created.chatId, text: question, sendMode: "normal", parseMarkdown: true })
        if (receipt.messageId === null) return result("unknown", null, event, "Thread creation is confirmed; question delivery has no message receipt. Inspect this thread before retrying. If this host supports Events continuation, subscribe from the returned cursor to recover any reply; otherwise disclose that automatic continuation is unavailable.")
        return result("sent", receipt.messageId.toString(), event, "The question was sent; no monitoring was installed by this tool. Open this chatId with conversations.open. If this host supports Events continuation, subscribe to message.created using the returned arguments and cursor and confirm registration before claiming to wait. On a reply, read current context and continue the originating task. In regular ChatGPT chats, explain that automatic continuation is unavailable; the user can read and reply in the thread view.")
      } catch {
        return result("unknown", null, event, "Thread creation is confirmed; question delivery is uncertain. Inspect this chat before retrying and do not recreate it. If this host supports Events continuation, subscribe from the returned cursor to recover any reply; otherwise disclose that automatic continuation is unavailable.")
      }
    })
  }

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
        "Resolve a person by name, @username, or user ID across allowed DMs and spaces without exposing phone or email. Use userId for sender filters and participant selection; use dmChatId or conversations.list to resolve the chat ID required by current DM tools.",
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
        "Find the chatId for a person, DM, thread, or space chat before reading or sending. Query can be a contact name, @username, chat title, or chat ID. Use kind or spaceId to narrow approved conversations. For complete archive discovery, omit query, set includeSubthreads true and sort id, and continue with nextAfterChatId as afterChatId until null. This includes authorized hidden subthreads and requires an Inline server with includeSubthreads support. Filters apply before pagination.",
      inputSchema: {
        query: z.string().min(1).optional().describe("Optional contact name, chat title, or chat ID"),
        spaceId: z.string().regex(/^[1-9]\d*$/).optional().describe("Only conversations in this approved space; incompatible with dm or home_thread kind"),
        kind: z.enum(["dm", "home_thread", "space_chat"]).optional().describe("Restrict the result to DMs, home threads, or space chats"),
        includeSubthreads: z.boolean().optional().describe("Request a complete authorized catalog including hidden subthreads; requires id sort and no query"),
        afterChatId: z.string().regex(/^[1-9]\d*$/).optional().describe("Exclusive ascending chat ID cursor; requires id sort and no query"),
        limit: submissionV2
          ? z.number().int().min(1).max(50).optional().describe("Maximum conversations to return; defaults to 20")
          : z.number().int().min(1).max(50).default(20).describe("Maximum conversations to return"),
        unreadOnly: submissionV2
          ? z.boolean().optional().describe("Only include conversations with unread messages; defaults to false")
          : z.boolean().default(false).describe("Only include conversations with unread messages"),
        sort: z
          .enum(["relevance", "recent", "unread", "id"])
          .optional()
          .describe("Sort mode. Defaults to relevance for queries, recent for ordinary lists, or ascending id for archive discovery/pagination."),
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
      { query, limit, unreadOnly, sort, spaceId, kind, includeSubthreads, afterChatId }: { query?: string; limit?: number; unreadOnly?: boolean; sort?: ConversationSort; spaceId?: string; kind?: InlineEligibleChat["kind"]; includeSubthreads?: boolean; afterChatId?: string },
      extra: { authInfo?: AuthInfo },
    ) => {
      const auth = extra.authInfo
      const scopes = auth?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:read")

      const safeLimit = Math.max(1, Math.min(50, limit ?? 20))
      const safeQuery = query?.trim()
      const onlyUnread = unreadOnly === true
      const completeCatalog = includeSubthreads === true
      const safeSort = parseConversationSort(sort ?? (completeCatalog || afterChatId ? "id" : undefined), !!safeQuery)
      const parsedAfterChatId = afterChatId ? parseChatId(afterChatId) : undefined
      if ((completeCatalog || parsedAfterChatId != null || safeSort === "id") && (safeQuery || safeSort !== "id")) {
        throw new Error("archive discovery and afterChatId require id sort and no query")
      }
      const parsedSpaceId = spaceId ? parseInlineId(spaceId, "spaceId") : undefined
      if (parsedSpaceId != null && !params.grant.spaceIds.includes(parsedSpaceId)) throw new Error("space is not in allowed context")
      if (parsedSpaceId != null && kind != null && kind !== "space_chat") throw new Error("spaceId requires kind space_chat or no kind filter")
      const matchesFilters = (chat: InlineEligibleChat): boolean =>
        (!onlyUnread || chat.unreadCount > 0) && (parsedSpaceId == null || chat.spaceId === parsedSpaceId) && (kind == null || chat.kind === kind)

      if (!safeQuery) {
        const chats = completeCatalog ? await params.inline.getEligibleChats({ includeSubthreads: true }) : await params.inline.getEligibleChats()
        const filtered = chats.filter(matchesFilters)
        const ordered = sortedConversations(filtered, safeSort).filter((chat) => parsedAfterChatId == null || chat.chatId > parsedAfterChatId)
        const selected = ordered.slice(0, safeLimit)
        const items = selected
          .map((chat, index) => conversationListItem(chat, index + 1))
        const payload = {
          query: null,
          sort: safeSort,
          bestMatch: null,
          unreadOnly: onlyUnread,
          spaceId: parsedSpaceId?.toString() ?? null,
          kind: kind ?? null,
          items,
          nextAfterChatId: safeSort === "id" && ordered.length > selected.length ? selected[selected.length - 1]!.chatId.toString() : null,
        }
        return {
          structuredContent: payload,
          content: [jsonText(payload)],
        }
      }

      const resolved = await params.inline.resolveConversation(safeQuery, safeLimit, { spaceId: parsedSpaceId, kind, unreadOnly: onlyUnread, sort: safeSort === "id" ? "recent" : safeSort })
      const filtered = resolved.candidates.filter(matchesFilters)
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
        spaceId: parsedSpaceId?.toString() ?? null,
        kind: kind ?? null,
        items,
        nextAfterChatId: null,
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
        ? "Use this tool after resolving a chatId to inspect conversation metadata, direct participants, explicit group-grant count, pinned message IDs, and parent/thread details before reading or sending. DMs also use chatId. Direct participants and group-grant count do not enumerate group members or inherited root-chat access and are not a complete audience list."
        : "Use this tool after resolving a chatId or DM userId to inspect conversation metadata, direct participants, explicit group-grant count, pinned message IDs, and parent/thread details before reading or sending. Direct participants and group-grant count do not enumerate group members or inherited root-chat access and are not a complete audience list.",
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
    "conversations.create_subthread",
    {
      title: "Create Inline Subthread",
      description: "Create a child of one resolved parent chat. The child inherits root-chat access plus its own direct/group grants. Participants added only to an intermediate child are not automatically inherited by descendants. participantUserIds adds access to a new child and cannot restrict root-chat access. Omit parentMessageId for an independent child, or supply it to create or reuse the reply thread for that message. An existing reply thread is returned without changing its title, description, emoji, or participants; these inputs apply only to new creation. Newly created private children include the creator directly; reuse does not repair older creator membership. Children outside spaces require home thread access. Use the returned chat.chatId for reading, sending, or forwarding.",
      inputSchema: {
        parentChatId: z.string().regex(/^[1-9]\d*$/).describe("Parent Inline chat ID, including a DM chat ID"),
        parentMessageId: z.string().regex(/^[1-9]\d*$/).optional().describe("Optional message ID in the parent; an existing reply thread is reused without changing metadata or participants"),
        title: z.string().min(1).max(200).optional().describe("Optional title for a new child; omit to use the server's default; ignored on reuse"),
        description: z.string().max(1000).optional().describe("Optional description for a new child; ignored on reuse"),
        emoji: z.string().max(16).optional().describe("Optional emoji icon for a new child; ignored on reuse"),
        participantUserIds: z.array(z.string().regex(/^[1-9]\d*$/)).max(50).optional().describe("Additional direct participants for a new child; ignored on reuse; root-chat access is retained and intermediate-child additions are not inherited"),
      },
      outputSchema: subthreadCreatedOutputSchema,
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
      _meta: toolMeta(["messages:write"], "Creating subthread...", "Subthread ready"),
    },
    async (args: { parentChatId: string; parentMessageId?: string; title?: string; description?: string; emoji?: string; participantUserIds?: string[] }, extra) => {
      requireScope(extra.authInfo?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean), "messages:write")
      const created = await params.inline.createSubthread({
        parentChatId: parseInlineId(args.parentChatId, "parentChatId"),
        ...(args.parentMessageId ? { parentMessageId: parseInlineId(args.parentMessageId, "parentMessageId") } : {}),
        ...(args.title != null ? { title: args.title } : {}),
        ...(args.description != null ? { description: args.description } : {}),
        ...(args.emoji != null ? { emoji: args.emoji } : {}),
        participantUserIds: coerceBigIntArray(args.participantUserIds, "participantUserIds"),
      })
      const payload = {
        chat: chatMetadata(created.chat),
        parentChatId: created.parentChatId.toString(),
        parentMessageId: created.parentMessageId?.toString() ?? null,
        anchorMessageId: created.anchorMessageId?.toString() ?? null,
      }
      return { structuredContent: payload, content: [jsonText(payload)] }
    },
  )

  registerInlineTool(
    server,
    resourceMetadataUrl,
    "messages.get",
    {
      title: "Get Inline Messages By ID",
      description: "Read exact message IDs from one resolved chat, including a DM. Results follow the requested order, with duplicate requests collapsed and unavailable IDs listed in missingMessageIds. Use this to inspect a selection before forwarding or verify known delivery receipts; use messages.context for surrounding discussion.",
      inputSchema: {
        chatId: z.string().regex(/^[1-9]\d*$/).describe("Inline chat ID"),
        messageIds: z.array(z.string().regex(/^[1-9]\d*$/)).min(1).max(100).describe("One to one hundred IDs scoped to this chat"),
      },
      outputSchema: messagesGetOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
      _meta: toolMeta(["messages:read"], "Getting selected messages...", "Selected messages loaded"),
    },
    async (args: { chatId: string; messageIds: string[] }, extra) => {
      requireScope(extra.authInfo?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean), "messages:read")
      const messageIds = [...new Set(coerceBigIntArray(args.messageIds, "messageIds"))]
      const found = await params.inline.getMessages({ chatId: parseChatId(args.chatId), messageIds })
      const byId = new Map(found.messages.map((message) => [message.id, message]))
      const payload = {
        chat: chatMetadata(found.chat),
        messageIds: messageIds.map(String),
        missingMessageIds: messageIds.filter((id) => !byId.has(id)).map(String),
        messages: messageIds.flatMap((id) => byId.has(id) ? [messagePayload(byId.get(id)!)] : []),
      }
      return { structuredContent: payload, content: [jsonText(payload)] }
    },
  )

  registerInlineTool(
    server,
    resourceMetadataUrl,
    "messages.forward",
    {
      title: "Forward Inline Messages",
      description: "Forward selected messages from a resolved source chat to a separately resolved destination chat, preserving the input order and media. Both chats must be approved by this grant. Resolve source and destination independently and inspect selected messages before forwarding. Returns ordered source/destination message ID pairs. Sending is not atomic or idempotent: an error may follow partial delivery, so inspect the destination before retrying to avoid duplicates. Forwarding headers follow server policy even when requested.",
      inputSchema: {
        sourceChatId: z.string().regex(/^[1-9]\d*$/).describe("Chat containing the messages, including a DM"),
        destinationChatId: z.string().regex(/^[1-9]\d*$/).describe("Chat receiving the forwarded messages, including a DM"),
        messageIds: z.array(z.string().regex(/^[1-9]\d*$/)).min(1).max(100).describe("Source message IDs in the desired delivery order; repeated IDs are forwarded repeatedly"),
        shareForwardHeader: z.boolean().optional().describe("Request the original attribution header; defaults to true, subject to server policy"),
      },
      outputSchema: messagesForwardOutputSchema,
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true },
      _meta: toolMeta(["messages:read", "messages:write"], "Forwarding selected messages...", "Messages forwarded"),
    },
    async (args: { sourceChatId: string; destinationChatId: string; messageIds: string[]; shareForwardHeader?: boolean }, extra) => {
      const scopes = extra.authInfo?.scopes ?? params.grant.scope.split(/\s+/).filter(Boolean)
      requireScope(scopes, "messages:read")
      requireScope(scopes, "messages:write")
      const messageIds = coerceBigIntArray(args.messageIds, "messageIds")
      const forwarded = await params.inline.forwardMessages({
        sourceChatId: parseInlineId(args.sourceChatId, "sourceChatId"),
        destinationChatId: parseInlineId(args.destinationChatId, "destinationChatId"),
        messageIds,
        ...(args.shareForwardHeader != null ? { shareForwardHeader: args.shareForwardHeader } : {}),
      })
      const payload = {
        ok: true as const,
        sourceChat: chatMetadata(forwarded.sourceChat),
        destinationChat: chatMetadata(forwarded.destinationChat),
        messages: forwarded.messages.map(({ sourceMessageId, destinationMessageId }) => ({
          sourceMessageId: sourceMessageId.toString(),
          destinationMessageId: destinationMessageId.toString(),
          uri: messageUri(forwarded.destinationChat.chatId, destinationMessageId),
        })),
      }
      return { structuredContent: payload, content: [jsonText(payload)] }
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
    "messages.list",
    {
      title: "List Inline Messages",
      description: submissionV2
        ? "Read recent context from one resolved chatId, including DMs. Results are newest first. Optional time, content, and sender filters scan at most 500 source messages. Continue with nextOffsetId as offsetId, including after an empty filtered page. Calendar days use UTC."
        : "Read recent context from one resolved chatId or DM userId. Results are newest first. Optional time, content, and sender filters scan at most 500 source messages. Continue with nextOffsetId as offsetId, including after an empty filtered page. Calendar days use UTC.",
      inputSchema: submissionV2
        ? {
            chatId: z.string().regex(/^[1-9]\d*$/).describe("Inline chat ID; required for every conversation, including DMs"),
            limit: z.number().int().min(1).max(50).optional().describe("Maximum messages to return; defaults to 20"),
            offsetId: z.string().regex(/^[1-9]\d*$/).optional().describe("Fetch messages older than this message ID"),
            senderUserId: z.string().regex(/^[1-9]\d*$/).optional().describe("Only messages sent by this user ID; use account.me for your ID or people.search to resolve another sender"),
            since: z.string().min(1).optional().describe("Lower time bound (e.g. yesterday, 2d ago, 2026-02-20)"),
            until: z.string().min(1).optional().describe("Upper time bound"),
            content: z.enum(["all", "links", "media", "photos", "videos", "documents", "files"]).optional().describe("Content type filter; defaults to all"),
          }
        : {
            chatId: z.string().min(1).optional().describe("Inline chat ID"),
            userId: z.string().min(1).optional().describe("Inline user ID (DM target)"),
            limit: z.number().int().min(1).max(50).default(20).describe("Maximum messages to return"),
            offsetId: z.string().min(1).optional().describe("Fetch messages older than this message ID"),
            senderUserId: z.string().regex(/^[1-9]\d*$/).optional().describe("Only messages sent by this user ID"),
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
      _meta: {
        ...toolMeta(["messages:read"], "Listing messages...", "Messages listed"),
        ui: { resourceUri: MESSAGE_RESULTS_RESOURCE_URI, ...(submissionV2 ? { visibility: ["model", "app"] } : {}) },
      },
    },
    async (
      {
        chatId,
        userId,
        limit,
        offsetId,
        senderUserId,
        since,
        until,
        content,
      }: {
        chatId?: string
        userId?: string
        limit?: number
        offsetId?: string
        senderUserId?: string
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
      const { parsedSince, parsedUntil } = parseTimeRange(since, until)
      const safeContent = parseContentFilter(content)
      const recent = await params.inline.recentMessages({
        ...target,
        limit: limit ?? 20,
        offsetId: parsedOffsetId,
        ...(senderUserId ? { senderUserId: parseUserId(senderUserId) } : {}),
        since: parsedSince,
        until: parsedUntil,
        content: safeContent,
      })
      const messages = recent.messages.map((message) => namedMessagePayload(message, recent.senderDisplayNames))

      const payload = {
        chat: chatMetadata(recent.chat),
        nextOffsetId: recent.nextOffsetId?.toString() ?? null,
        scannedCount: recent.scannedCount,
        senderUserId: senderUserId ?? null,
        since: parsedSince?.toString() ?? null,
        until: parsedUntil?.toString() ?? null,
        content: safeContent,
        messages,
      }

      return {
        structuredContent: payload,
        content: [jsonText(payload)],
        ...(Object.keys(recent.senderAvatarUrls ?? {}).length ? { _meta: { inline: { senderAvatarUrls: recent.senderAvatarUrls } } } : {}),
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
        ? "Search text within one resolved chatId, including DMs. Space-separated terms are ANDed. Results are newest first. Time and sender filters apply after the server's bounded search page, so an empty filtered page may have older matches: continue with nextOffsetId as offsetId until it is null. Calendar days use UTC. Use messages.list for filters without search text."
        : "Search within one resolved chatId or DM userId. Space-separated terms are ANDed. Time and sender filters apply after the server's bounded search page; continue with nextOffsetId as offsetId even when a filtered page is empty. Calendar days use UTC. Use conversations.list when the target is unclear.",
      inputSchema: submissionV2
        ? {
            chatId: z.string().regex(/^[1-9]\d*$/).describe("Inline chat ID; required for every conversation, including DMs"),
            query: z.string().min(1).describe("Text to search for in this conversation"),
            offsetId: z.string().regex(/^[1-9]\d*$/).optional().describe("Continue search older than this message ID, using nextOffsetId from the previous result"),
            senderUserId: z.string().regex(/^[1-9]\d*$/).optional().describe("Only messages sent by this user ID; applied after the search page limit"),
            limit: z.number().int().min(1).max(50).optional().describe("Maximum messages to return; defaults to 20"),
            since: z.string().min(1).optional().describe("Lower time bound"),
            until: z.string().min(1).optional().describe("Upper time bound"),
            content: z.enum(["all", "links", "media", "photos", "videos", "documents", "files"]).optional().describe("Content type filter; defaults to all"),
          }
        : {
            chatId: z.string().min(1).optional().describe("Inline chat ID"),
            userId: z.string().min(1).optional().describe("Inline user ID (DM target)"),
            query: z.string().min(1).optional().describe("Optional search query"),
            offsetId: z.string().regex(/^[1-9]\d*$/).optional().describe("Continue search older than this message ID"),
            senderUserId: z.string().regex(/^[1-9]\d*$/).optional().describe("Only messages sent by this user ID; applied after the search page limit"),
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
      _meta: {
        ...toolMeta(["messages:read"], "Searching messages in chat...", "Message search complete"),
        ui: { resourceUri: MESSAGE_RESULTS_RESOURCE_URI, ...(submissionV2 ? { visibility: ["model", "app"] } : {}) },
      },
    },
    async (
      {
        chatId,
        userId,
        query,
        offsetId,
        senderUserId,
        limit,
        since,
        until,
        content,
      }: {
        chatId?: string
        userId?: string
        query?: string
        offsetId?: string
        senderUserId?: string
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
      if (submissionV2 && !query?.trim()) throw new Error("query must contain non-whitespace text; use messages.list for filter-only reads")
      const { parsedSince, parsedUntil } = parseTimeRange(since, until)
      const safeContent = parseContentFilter(content)
      const found: InlineSearchMessagesResult = await params.inline.searchMessages({
        ...target,
        query,
        ...(offsetId ? { offsetId: parseInlineId(offsetId, "offsetId") } : {}),
        ...(senderUserId ? { senderUserId: parseUserId(senderUserId) } : {}),
        limit: limit ?? 20,
        since: parsedSince,
        until: parsedUntil,
        content: safeContent,
      })

      const messages = found.messages.map((message) => namedMessagePayload(message, found.senderDisplayNames))

      const payload = {
        query: found.query,
        content: found.content,
        since: parsedSince?.toString() ?? null,
        until: parsedUntil?.toString() ?? null,
        chat: chatMetadata(found.chat),
        nextOffsetId: found.nextOffsetId?.toString() ?? null,
        scannedCount: found.scannedCount,
        senderUserId: senderUserId ?? null,
        messages,
      }

      return {
        structuredContent: payload,
        content: [jsonText(payload)],
        ...(Object.keys(found.senderAvatarUrls ?? {}).length ? { _meta: { inline: { senderAvatarUrls: found.senderAvatarUrls } } } : {}),
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

      const { parsedSince, parsedUntil } = parseTimeRange(since, until)
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
      _meta: { ...toolMeta(["messages:write"], "Sending Inline message...", "Message sent"), ...(submissionV2 ? { ui: { visibility: ["model", "app"] } } : {}) },
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
