import type { AnyAgentTool, OpenClawConfig } from "openclaw/plugin-sdk/core"
import { InlineSdkClient, Method } from "@inline-chat/realtime-sdk"
import { resolveInlineAccount, resolveInlineToken } from "./accounts.js"
import { getInlineRuntime } from "../runtime.js"

type InlineProfileToolArgs = {
  name?: string
  photoUrl?: string
  photoPath?: string
  photoFileUniqueId?: string
  accountId?: string
}

type InlineProfileToolResult = {
  content: Array<{ type: "text"; text: string }>
  details: unknown
}

type InlineLoadedMedia = Awaited<ReturnType<ReturnType<typeof getInlineRuntime>["media"]["loadWebMedia"]>>
type LoadWebMediaCompat = (
  mediaUrl: string,
  maxBytes?: number,
  options?: {
    ssrfPolicy?: unknown
    localRoots?: string[] | "any"
  },
) => Promise<InlineLoadedMedia>

const InlineProfileToolParameters = {
  type: "object",
  additionalProperties: false,
  properties: {
    name: {
      type: "string",
      description: "Optional new display name for the authenticated Inline bot.",
    },
    photoUrl: {
      type: "string",
      description: "Optional remote image URL to upload as the bot profile photo.",
    },
    photoPath: {
      type: "string",
      description: "Optional local image path to upload as the bot profile photo.",
    },
    photoFileUniqueId: {
      type: "string",
      description: "Optional existing Inline file unique id to use as the bot profile photo.",
    },
    accountId: {
      type: "string",
      description: "Optional Inline account id override.",
    },
  },
} as const

function jsonResult(payload: unknown): InlineProfileToolResult {
  return {
    content: [
      {
        type: "text",
        text: JSON.stringify(payload, (_key, value) => (typeof value === "bigint" ? value.toString() : value), 2),
      },
    ],
    details: payload,
  }
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

function readTrimmedString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined
  const trimmed = value.trim()
  return trimmed || undefined
}

function resolvePhotoSource(args: InlineProfileToolArgs): string | undefined {
  return readTrimmedString(args.photoPath) ?? readTrimmedString(args.photoUrl)
}

function looksLikeLocalMediaSource(mediaUrl: string): boolean {
  return !/^https?:\/\//i.test(mediaUrl.trim())
}

async function uploadProfilePhoto(client: InlineSdkClient, rawSource: string): Promise<string> {
  const runtimeMedia = getInlineRuntime().media
  const loadWebMediaCompat = runtimeMedia.loadWebMedia as unknown as LoadWebMediaCompat
  let loaded: InlineLoadedMedia
  try {
    loaded = await runtimeMedia.loadWebMedia(rawSource)
  } catch (error) {
    const message = String(error)
    const deniedLocalPath = /not under an allowed directory/i.test(message)
    if (!deniedLocalPath || !looksLikeLocalMediaSource(rawSource)) {
      throw error
    }
    loaded = await loadWebMediaCompat(rawSource, undefined, { localRoots: "any" })
  }
  const contentType =
    loaded.contentType ??
    (await runtimeMedia.detectMime({
      buffer: loaded.buffer,
      ...(loaded.fileName ? { filePath: loaded.fileName } : {}),
    })) ??
    undefined
  const fileName = loaded.fileName?.trim() || "profile-photo.png"
  const uploaded = await client.uploadFile({
    type: "photo",
    file: loaded.buffer,
    fileName,
    ...(contentType ? { contentType } : {}),
  })
  if (!uploaded.fileUniqueId) {
    throw new Error("inline_update_profile: upload did not return fileUniqueId")
  }
  return uploaded.fileUniqueId
}

export function createInlineProfileTool(ctx: {
  config?: OpenClawConfig
  agentAccountId?: string
}): AnyAgentTool | null {
  if (!ctx.config) {
    return null
  }

  return {
    name: "inline_update_profile",
    label: "Inline Update Profile",
    description:
      "Update the authenticated Inline bot profile name and/or profile photo.",
    parameters: InlineProfileToolParameters,
    execute: async (_toolCallId, rawArgs) => {
      const args = rawArgs as InlineProfileToolArgs
      const name = readTrimmedString(args.name)
      const existingPhotoFileUniqueId = readTrimmedString(args.photoFileUniqueId)
      const photoSource = resolvePhotoSource(args)

      if (!name && !existingPhotoFileUniqueId && !photoSource) {
        throw new Error("inline_update_profile: provide `name` and/or `photo`")
      }

      return await withInlineClient({
        cfg: ctx.config as OpenClawConfig,
        accountId: args.accountId ?? ctx.agentAccountId ?? null,
        fn: async (client, resolvedAccountId) => {
          const me = await client.getMe()
          const photoFileUniqueId =
            existingPhotoFileUniqueId ?? (photoSource ? await uploadProfilePhoto(client, photoSource) : undefined)

          const result = await client.invokeRaw(Method.UPDATE_BOT_PROFILE, {
            oneofKind: "updateBotProfile",
            updateBotProfile: {
              botUserId: me.userId,
              ...(name ? { name } : {}),
              ...(photoFileUniqueId ? { photoFileUniqueId } : {}),
            },
          })
          if (result.oneofKind !== "updateBotProfile") {
            throw new Error(
              `inline_update_profile: expected updateBotProfile result, got ${String(result.oneofKind)}`,
            )
          }

          return jsonResult({
            ok: true,
            accountId: resolvedAccountId,
            botUserId: String(me.userId),
            updated: {
              ...(name ? { name } : {}),
              photo: photoFileUniqueId != null,
            },
            bot: result.updateBotProfile.bot ?? null,
          })
        },
      })
    },
  } as AnyAgentTool
}
