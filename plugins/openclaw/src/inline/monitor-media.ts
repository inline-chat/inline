import path from "node:path"
import { toInboundMediaFacts } from "openclaw/plugin-sdk/channel-inbound"
import type { OpenClawConfig } from "openclaw/plugin-sdk/core"
import type { Message } from "@inline-chat/realtime-sdk"
import type { ResolvedInlineAccount } from "./accounts.js"
import { getInlineRuntime } from "../runtime.js"
import { summarizeInlineMessageContent } from "./message-content.js"
import { resolveChannelMediaMaxBytes } from "../openclaw-compat.js"

type InlineInboundMediaInfo = {
  path?: string
  contentType?: string | undefined
  fileName?: string | undefined
  kind?: "image" | "video" | "audio" | "document" | undefined
  messageId?: string | undefined
}

const DEFAULT_INLINE_MEDIA_MAX_BYTES = 300 * 1024 * 1024

export function resolveInlineMediaMaxBytes(params: {
  cfg: OpenClawConfig
  account: ResolvedInlineAccount
}): number {
  return (
    resolveChannelMediaMaxBytes({
      cfg: params.cfg,
      accountId: params.account.accountId,
      resolveChannelLimitMb: ({ accountId }) => {
        if (accountId != null && accountId !== params.account.accountId) return undefined
        return params.account.config.mediaMaxMb
      },
    }) ?? DEFAULT_INLINE_MEDIA_MAX_BYTES
  )
}

export function buildInlineInboundMediaFacts(media: InlineInboundMediaInfo[]) {
  return toInboundMediaFacts(media.map((item) => ({
    ...(item.path ? { path: item.path } : {}),
    ...(item.contentType?.trim() ? { contentType: item.contentType.trim() } : {}),
    ...(item.fileName?.trim() ? { fileName: item.fileName.trim() } : {}),
    ...(item.kind ? { kind: item.kind } : {}),
    ...(item.messageId ? { messageId: item.messageId } : {}),
  })))
}

export function buildInlineInboundBodyText(content: ReturnType<typeof summarizeInlineMessageContent>): string {
  if (content.rawText) return content.rawText
  if (content.media?.kind === "nudge" || (!content.media && content.attachmentText)) {
    return content.text
  }
  return ""
}

function resolveFilePathHint(params: { sourceUrl: string; preferredName?: string | null | undefined }): string | undefined {
  const preferred = params.preferredName?.trim()
  if (preferred) return preferred

  try {
    const pathname = new URL(params.sourceUrl).pathname
    const base = path.basename(pathname).trim()
    if (base) return base
  } catch {
    // ignore malformed urls and let the media pipeline choose a filename
  }

  return undefined
}

export async function resolveInlineInboundMedia(params: {
  core: ReturnType<typeof getInlineRuntime>
  message: Message
  maxBytes: number
  log?: { warn?: (msg: string) => void; debug?: (msg: string) => void } | undefined
}): Promise<InlineInboundMediaInfo[]> {
  const content = summarizeInlineMessageContent(params.message)
  const candidates = new Map<
    string,
    {
      fileName?: string | null
      mimeType?: string | null
      kind: "image" | "video" | "audio" | "document"
    }
  >()

  const out: InlineInboundMediaInfo[] = []
  const messageId = String(params.message.id)
  const inlineMediaKind = content.media?.kind === "photo"
    ? "image"
    : content.media?.kind === "video"
      ? "video"
      : content.media?.kind === "voice"
        ? "audio"
        : content.media?.kind === "document"
          ? "document"
          : null

  if (content.media?.url) {
    candidates.set(content.media.url, {
      fileName: content.media.fileName ?? null,
      mimeType: content.media.mimeType ?? null,
      kind: inlineMediaKind ?? "document",
    })
  } else if (inlineMediaKind) {
    out.push({
      kind: inlineMediaKind,
      ...(content.media?.fileName ? { fileName: content.media.fileName } : {}),
      ...(content.media?.mimeType ? { contentType: content.media.mimeType } : {}),
      messageId,
    })
  }

  for (const attachment of content.attachments) {
    if (attachment.kind !== "urlPreview" || !attachment.previewImageUrl) continue
    candidates.set(attachment.previewImageUrl, {
      mimeType: null,
      kind: "image",
    })
  }

  for (const [url, candidate] of candidates.entries()) {
    try {
      const filePathHint = resolveFilePathHint({ sourceUrl: url, preferredName: candidate.fileName })
      const fetched = await params.core.channel.media.readRemoteMediaBuffer({
        url,
        maxBytes: params.maxBytes,
        ...(filePathHint ? { filePathHint } : {}),
      })
      const fetchedContentType = fetched.contentType ?? candidate.mimeType ?? undefined
      const saved = await params.core.channel.media.saveMediaBuffer(
        fetched.buffer,
        fetchedContentType,
        "inbound",
        params.maxBytes,
        fetched.fileName ?? candidate.fileName ?? undefined,
      )
      const contentType = saved.contentType ?? fetchedContentType
      const fileName = fetched.fileName ?? candidate.fileName
      out.push({
        path: saved.path,
        ...(contentType ? { contentType } : {}),
        ...(fileName ? { fileName } : {}),
        // Documents may contain image/audio bytes; keep the host's MIME inference.
        ...(candidate.kind !== "document" ? { kind: candidate.kind } : {}),
        messageId,
      })
    } catch (err) {
      params.log?.warn?.(`inline: failed to download inbound media ${url}: ${String(err)}`)
      out.push({
        kind: candidate.kind,
        ...(candidate.fileName ? { fileName: candidate.fileName } : {}),
        ...(candidate.mimeType ? { contentType: candidate.mimeType } : {}),
        messageId,
      })
    }
  }

  return out
}
