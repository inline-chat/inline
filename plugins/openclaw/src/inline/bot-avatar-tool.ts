import { inflateRawSync } from "node:zlib"
import path from "node:path"
import { fileURLToPath } from "node:url"
import os from "node:os"
import type { AnyAgentTool, OpenClawConfig } from "openclaw/plugin-sdk/core"
import { BotAvatar_Kind, InlineSdkClient, Method } from "@inline-chat/realtime-sdk"
import { resolveInlineAccount, resolveInlineToken } from "./accounts.js"
import { sanitizeInlineVisibleText } from "./outbound-sanitize.js"
import { jsonResult } from "../openclaw-compat.js"
import { getInlineRuntime } from "../runtime.js"

const MAX_PACKAGE_BYTES = 40_000_000
const MAX_MANIFEST_BYTES = 64_000
const ZIP_EOCD_SIGNATURE = 0x06054b50
const ZIP_CENTRAL_SIGNATURE = 0x02014b50
const ZIP_LOCAL_SIGNATURE = 0x04034b50
const ZIP_METHOD_STORE = 0
const ZIP_METHOD_DEFLATE = 8
const ZIP_FLAG_ENCRYPTED = 1
const CODEX_ATLAS_KIND = "codex_atlas"
const SET_BOT_AVATAR_METHOD =
  typeof (Method as Record<string, unknown>).SET_BOT_AVATAR === "number" &&
  Number.isInteger((Method as Record<string, unknown>).SET_BOT_AVATAR) &&
  ((Method as Record<string, unknown>).SET_BOT_AVATAR as number) > 0
    ? ((Method as Record<string, unknown>).SET_BOT_AVATAR as Method)
    : (56 as Method)
const CLEAR_BOT_AVATAR_METHOD =
  typeof (Method as Record<string, unknown>).CLEAR_BOT_AVATAR === "number" &&
  Number.isInteger((Method as Record<string, unknown>).CLEAR_BOT_AVATAR) &&
  ((Method as Record<string, unknown>).CLEAR_BOT_AVATAR as number) > 0
    ? ((Method as Record<string, unknown>).CLEAR_BOT_AVATAR as Method)
    : (57 as Method)

type InlineBotAvatarToolArgs = {
  action?: string
  clear?: boolean
  zipPath?: string
  archivePath?: string
  zipUrl?: string
  source?: string
  displayName?: string
  description?: string
  accountId?: string
}

type ZipEntry = {
  name: string
  method: number
  flags: number
  compressedSize: number
  uncompressedSize: number
  localHeaderOffset: number
}

type AvatarPackage = {
  id?: string
  displayName: string
  description?: string
  spritesheetPath: string
  spritesheet: Buffer
  contentType: "image/png" | "image/webp"
  fileName: string
}

type RuntimeMedia = ReturnType<typeof getInlineRuntime>["media"]
type LoadedMedia = Awaited<ReturnType<RuntimeMedia["loadWebMedia"]>>
type ToolFsPolicy = {
  workspaceOnly?: boolean
}
type PackageLoadContext = {
  workspaceDir?: string
  fsPolicy?: ToolFsPolicy
}
type PackageLoadOptions = {
  maxBytes: number
  optimizeImages: false
  workspaceDir?: string
  localRoots?: readonly string[]
}

const InlineBotAvatarToolParameters = {
  type: "object",
  additionalProperties: false,
  properties: {
    action: {
      type: "string",
      enum: ["set", "clear"],
      description: "Avatar operation. Defaults to `set`; use `clear` to remove the current bot avatar.",
    },
    clear: {
      type: "boolean",
      description: "Boolean alias for action: clear.",
    },
    zipPath: {
      type: "string",
      description:
        "Local path to a .zip avatar package. The archive should contain a Codex atlas manifest and a PNG/WebP spritesheet.",
    },
    archivePath: {
      type: "string",
      description: "Alias for zipPath.",
    },
    zipUrl: {
      type: "string",
      description: "Remote URL to a .zip avatar package.",
    },
    source: {
      type: "string",
      description: "Local path or URL alias for the avatar package .zip.",
    },
    displayName: {
      type: "string",
      description: "Optional display-name override for the uploaded bot avatar.",
    },
    description: {
      type: "string",
      description: "Optional short description override for the uploaded bot avatar.",
    },
    accountId: {
      type: "string",
      description: "Optional Inline account id override.",
    },
  },
} as const

function readTrimmedString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined
  const trimmed = value.trim()
  return trimmed || undefined
}

function readVisibleString(value: unknown, label: string): string | undefined {
  const raw = readTrimmedString(value)
  if (!raw) return undefined
  const visible = sanitizeInlineVisibleText(raw)
  if (visible.shouldSkip) {
    throw new Error(`inline_bot_avatar: ${label} contains internal runtime text`)
  }
  return readTrimmedString(visible.text)
}

function resolvePackageSource(args: InlineBotAvatarToolArgs): string {
  const source =
    readTrimmedString(args.zipPath) ??
    readTrimmedString(args.archivePath) ??
    readTrimmedString(args.zipUrl) ??
    readTrimmedString(args.source)
  if (!source) {
    throw new Error("inline_bot_avatar: provide `zipPath` or `source`")
  }
  const sourceWithoutQuery = source.split(/[?#]/, 1)[0] ?? source
  if (!sourceWithoutQuery.toLowerCase().endsWith(".zip")) {
    throw new Error("inline_bot_avatar: source must be a .zip package")
  }
  return source
}

function resolveAvatarAction(args: InlineBotAvatarToolArgs): "set" | "clear" {
  if (args.clear === true) return "clear"
  const action = readTrimmedString(args.action)?.toLowerCase()
  if (!action || action === "set" || action === "install" || action === "replace") return "set"
  if (action === "clear" || action === "remove" || action === "delete") return "clear"
  throw new Error(`inline_bot_avatar: invalid action "${args.action}"`)
}

function assertClearArgs(args: InlineBotAvatarToolArgs): void {
  if (
    readTrimmedString(args.zipPath) ||
    readTrimmedString(args.archivePath) ||
    readTrimmedString(args.zipUrl) ||
    readTrimmedString(args.source) ||
    readTrimmedString(args.displayName) ||
    readTrimmedString(args.description)
  ) {
    throw new Error("inline_bot_avatar: clear action must not include avatar package or display metadata")
  }
}

function sourceWithoutQuery(raw: string): string {
  return raw.split(/[?#]/, 1)[0] ?? raw
}

function localPathFromSource(source: string): string | undefined {
  const trimmed = source.trim()
  if (!trimmed || /^https?:\/\//i.test(trimmed)) return undefined
  if (trimmed.startsWith("file://")) {
    try {
      return fileURLToPath(trimmed)
    } catch {
      return undefined
    }
  }
  const withoutQuery = sourceWithoutQuery(trimmed)
  if (withoutQuery.startsWith("~/") || withoutQuery === "~") {
    return path.join(os.homedir(), withoutQuery.slice(2))
  }
  if (path.isAbsolute(withoutQuery)) return withoutQuery
  return undefined
}

function packageLoadOptions(source: string, ctx: PackageLoadContext): PackageLoadOptions {
  const options: PackageLoadOptions = {
    maxBytes: MAX_PACKAGE_BYTES,
    optimizeImages: false,
    ...(ctx.workspaceDir ? { workspaceDir: ctx.workspaceDir } : {}),
  }
  const localPath = localPathFromSource(source)
  if (!localPath) return options

  if (ctx.fsPolicy?.workspaceOnly === true) {
    if (ctx.workspaceDir) return { ...options, localRoots: [ctx.workspaceDir] }
    return options
  }

  return {
    ...options,
    localRoots: [path.dirname(localPath)],
  }
}

function sanitizeUploadFileName(raw: string): string {
  const normalized = raw.trim().replace(/\\/g, "/")
  const leaf = normalized.split("/").pop() ?? normalized
  const safe = leaf.split(/[?#]/, 1)[0]?.trim()
  return safe || "bot-avatar.webp"
}

function normalizeZipName(raw: string): string {
  const normalized = raw.replace(/\\/g, "/")
  const parts = normalized.split("/").filter((part) => part.length > 0)
  if (normalized.startsWith("/") || parts.some((part) => part === "." || part === "..")) {
    throw new Error(`inline_bot_avatar: invalid zip entry path "${raw}"`)
  }
  return parts.join("/")
}

function findEndOfCentralDirectory(data: Buffer): number {
  const minOffset = Math.max(0, data.length - 0xffff - 22)
  for (let offset = data.length - 22; offset >= minOffset; offset -= 1) {
    if (data.readUInt32LE(offset) === ZIP_EOCD_SIGNATURE) return offset
  }
  throw new Error("inline_bot_avatar: invalid zip package")
}

function readZipEntries(data: Buffer): Map<string, ZipEntry> {
  const eocdOffset = findEndOfCentralDirectory(data)
  const totalEntries = data.readUInt16LE(eocdOffset + 10)
  const centralSize = data.readUInt32LE(eocdOffset + 12)
  const centralOffset = data.readUInt32LE(eocdOffset + 16)
  if (totalEntries === 0xffff || centralSize === 0xffffffff || centralOffset === 0xffffffff) {
    throw new Error("inline_bot_avatar: zip64 packages are not supported")
  }
  if (centralOffset + centralSize > data.length) {
    throw new Error("inline_bot_avatar: invalid zip central directory")
  }

  const entries = new Map<string, ZipEntry>()
  let offset = centralOffset
  for (let index = 0; index < totalEntries; index += 1) {
    if (offset + 46 > data.length || data.readUInt32LE(offset) !== ZIP_CENTRAL_SIGNATURE) {
      throw new Error("inline_bot_avatar: invalid zip central directory entry")
    }
    const flags = data.readUInt16LE(offset + 8)
    const method = data.readUInt16LE(offset + 10)
    const compressedSize = data.readUInt32LE(offset + 20)
    const uncompressedSize = data.readUInt32LE(offset + 24)
    const fileNameLength = data.readUInt16LE(offset + 28)
    const extraLength = data.readUInt16LE(offset + 30)
    const commentLength = data.readUInt16LE(offset + 32)
    const localHeaderOffset = data.readUInt32LE(offset + 42)
    const fileNameStart = offset + 46
    const fileNameEnd = fileNameStart + fileNameLength
    if (fileNameEnd > data.length) {
      throw new Error("inline_bot_avatar: invalid zip file name")
    }
    const rawName = data.subarray(fileNameStart, fileNameEnd).toString("utf8")
    offset = fileNameEnd + extraLength + commentLength
    if (!rawName || rawName.endsWith("/")) continue
    const name = normalizeZipName(rawName)
    entries.set(name, {
      name,
      method,
      flags,
      compressedSize,
      uncompressedSize,
      localHeaderOffset,
    })
  }
  return entries
}

function readZipEntry(data: Buffer, entry: ZipEntry, maxBytes: number): Buffer {
  if ((entry.flags & ZIP_FLAG_ENCRYPTED) !== 0) {
    throw new Error(`inline_bot_avatar: encrypted zip entry is not supported (${entry.name})`)
  }
  if (entry.uncompressedSize > maxBytes) {
    throw new Error(`inline_bot_avatar: zip entry is too large (${entry.name})`)
  }
  if (entry.localHeaderOffset + 30 > data.length || data.readUInt32LE(entry.localHeaderOffset) !== ZIP_LOCAL_SIGNATURE) {
    throw new Error(`inline_bot_avatar: invalid zip local header (${entry.name})`)
  }
  const nameLength = data.readUInt16LE(entry.localHeaderOffset + 26)
  const extraLength = data.readUInt16LE(entry.localHeaderOffset + 28)
  const dataStart = entry.localHeaderOffset + 30 + nameLength + extraLength
  const dataEnd = dataStart + entry.compressedSize
  if (dataEnd > data.length) {
    throw new Error(`inline_bot_avatar: invalid zip entry data (${entry.name})`)
  }

  const compressed = data.subarray(dataStart, dataEnd)
  let bytes: Buffer | undefined
  try {
    bytes =
      entry.method === ZIP_METHOD_STORE
        ? Buffer.from(compressed)
        : entry.method === ZIP_METHOD_DEFLATE
          ? inflateRawSync(compressed, { maxOutputLength: maxBytes + 1 })
          : undefined
  } catch (error) {
    throw new Error(`inline_bot_avatar: invalid or oversized zip entry (${entry.name})`, {
      cause: error as Error,
    })
  }
  if (!bytes) {
    throw new Error(`inline_bot_avatar: unsupported zip compression (${entry.name})`)
  }
  if (bytes.length !== entry.uncompressedSize || bytes.length > maxBytes) {
    throw new Error(`inline_bot_avatar: invalid zip entry size (${entry.name})`)
  }
  return bytes
}

function findPackageManifest(entries: Map<string, ZipEntry>): ZipEntry {
  const root = entries.get("pet.json")
  if (root) return root
  for (const entry of entries.values()) {
    if (entry.name.endsWith("/pet.json")) return entry
  }
  throw new Error("inline_bot_avatar: package is missing avatar manifest")
}

function resolveRelativeZipPath(baseEntryName: string, rawPath: string): string {
  const baseDir = baseEntryName.includes("/") ? baseEntryName.slice(0, baseEntryName.lastIndexOf("/")) : ""
  return normalizeZipName(path.posix.normalize(path.posix.join(baseDir, rawPath)))
}

function parsePackageManifest(data: Buffer): Record<string, unknown> {
  try {
    const parsed = JSON.parse(data.toString("utf8")) as unknown
    if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>
    }
  } catch {
    // Use the uniform error below.
  }
  throw new Error("inline_bot_avatar: invalid avatar manifest")
}

function contentTypeForSprite(fileName: string): "image/png" | "image/webp" {
  const ext = path.extname(fileName).toLowerCase()
  if (ext === ".png") return "image/png"
  if (ext === ".webp") return "image/webp"
  throw new Error("inline_bot_avatar: spritesheet must be PNG or WebP")
}

function extractAvatarPackage(params: {
  data: Buffer
  source: string
  displayName?: string
  description?: string
}): AvatarPackage {
  const entries = readZipEntries(params.data)
  const manifestEntry = findPackageManifest(entries)
  const manifest = parsePackageManifest(readZipEntry(params.data, manifestEntry, MAX_MANIFEST_BYTES))
  const rawSpritesheetPath = readTrimmedString(manifest.spritesheetPath)
  if (!rawSpritesheetPath) {
    throw new Error("inline_bot_avatar: avatar manifest is missing spritesheetPath")
  }

  const spritesheetPath = resolveRelativeZipPath(manifestEntry.name, rawSpritesheetPath)
  const spriteEntry = entries.get(spritesheetPath)
  if (!spriteEntry) {
    throw new Error(`inline_bot_avatar: package is missing spritesheet ${rawSpritesheetPath}`)
  }

  const id = readTrimmedString(manifest.id)
  const fallbackName = sanitizeUploadFileName(params.source).replace(/\.zip$/i, "")
  const displayName =
    params.displayName ??
    readVisibleString(manifest.displayName, "displayName") ??
    id ??
    fallbackName
  const description = params.description ?? readVisibleString(manifest.description, "description")
  const fileName = sanitizeUploadFileName(spritesheetPath)

  return {
    ...(id ? { id } : {}),
    displayName,
    ...(description ? { description } : {}),
    spritesheetPath,
    spritesheet: readZipEntry(params.data, spriteEntry, MAX_PACKAGE_BYTES),
    contentType: contentTypeForSprite(fileName),
    fileName,
  }
}

async function loadPackage(source: string, ctx: PackageLoadContext): Promise<LoadedMedia> {
  return await getInlineRuntime().media.loadWebMedia(source, packageLoadOptions(source, ctx))
}

async function withInlineClient<T>(params: {
  cfg: OpenClawConfig
  accountId?: string | null
  fn: (client: InlineSdkClient, resolvedAccountId: string) => Promise<T>
}): Promise<T> {
  const account = resolveInlineAccount({ cfg: params.cfg, accountId: params.accountId ?? null })
  if (!account.configured || !account.baseUrl) {
    throw new Error(`Inline not configured for account "${account.accountId}" (missing token or baseUrl)`)
  }
  const token = await resolveInlineToken(account)
  const client = new InlineSdkClient({
    baseUrl: account.baseUrl,
    token,
  })
  await client.connect()
  try {
    return await params.fn(client, account.accountId)
  } finally {
    await client.close().catch(() => {})
  }
}

export function createInlineBotAvatarTool(ctx: {
  config?: OpenClawConfig
  agentAccountId?: string
  workspaceDir?: string
  fsPolicy?: ToolFsPolicy
}): AnyAgentTool | null {
  if (!ctx.config) return null

  return {
    name: "inline_bot_avatar",
    label: "Bot Avatar",
    description:
      "Install, replace, or clear the authenticated Inline bot's on-screen avatar. Zip package installs require a user-provided Codex atlas package. Use only when the user explicitly asks to manage your avatar.",
    parameters: InlineBotAvatarToolParameters,
    execute: async (_toolCallId, rawArgs) => {
      const args = rawArgs as InlineBotAvatarToolArgs
      const action = resolveAvatarAction(args)
      if (action === "clear") {
        assertClearArgs(args)
        return await withInlineClient({
          cfg: ctx.config as OpenClawConfig,
          accountId: args.accountId ?? ctx.agentAccountId ?? null,
          fn: async (client, resolvedAccountId) => {
            const me = await client.getMe()
            const result = await client.invokeRaw(CLEAR_BOT_AVATAR_METHOD, {
              oneofKind: "clearBotAvatar",
              clearBotAvatar: {
                botUserId: me.userId,
              },
            })
            if (result.oneofKind !== "clearBotAvatar") {
              throw new Error(`inline_bot_avatar: expected clearBotAvatar result, got ${String(result.oneofKind)}`)
            }

            return jsonResult({
              ok: true,
              action,
              accountId: resolvedAccountId,
              botUserId: String(me.userId),
              cleared: true,
              avatar: null,
              bot: result.clearBotAvatar.bot ?? null,
            })
          },
        })
      }

      const source = resolvePackageSource(args)
      const displayName = readVisibleString(args.displayName, "displayName")
      const description = readVisibleString(args.description, "description")
      const loaded = await loadPackage(source, ctx)
      const avatarPackage = extractAvatarPackage({
        data: Buffer.from(loaded.buffer),
        source,
        ...(displayName ? { displayName } : {}),
        ...(description ? { description } : {}),
      })

      return await withInlineClient({
        cfg: ctx.config as OpenClawConfig,
        accountId: args.accountId ?? ctx.agentAccountId ?? null,
        fn: async (client, resolvedAccountId) => {
          const me = await client.getMe()
          const uploaded = await client.uploadFile({
            type: "photo",
            file: avatarPackage.spritesheet,
            fileName: avatarPackage.fileName,
            contentType: avatarPackage.contentType,
          })
          if (!uploaded.fileUniqueId) {
            throw new Error("inline_bot_avatar: upload did not return fileUniqueId")
          }

          const result = await client.invokeRaw(SET_BOT_AVATAR_METHOD, {
            oneofKind: "setBotAvatar",
            setBotAvatar: {
              botUserId: me.userId,
              kind: BotAvatar_Kind.CODEX_ATLAS,
              displayName: avatarPackage.displayName,
              ...(avatarPackage.description ? { description: avatarPackage.description } : {}),
              fileUniqueId: uploaded.fileUniqueId,
            },
          })
          if (result.oneofKind !== "setBotAvatar") {
            throw new Error(`inline_bot_avatar: expected setBotAvatar result, got ${String(result.oneofKind)}`)
          }

          return jsonResult({
            ok: true,
            action,
            accountId: resolvedAccountId,
            botUserId: String(me.userId),
            avatar: {
              kind: CODEX_ATLAS_KIND,
              ...(avatarPackage.id ? { id: avatarPackage.id } : {}),
              displayName: avatarPackage.displayName,
              ...(avatarPackage.description ? { description: avatarPackage.description } : {}),
              spritesheetPath: avatarPackage.spritesheetPath,
            },
            uploaded: {
              fileUniqueId: uploaded.fileUniqueId,
              fileName: avatarPackage.fileName,
              contentType: avatarPackage.contentType,
            },
            bot: result.setBotAvatar.bot ?? null,
          })
        },
      })
    },
  } as AnyAgentTool
}
