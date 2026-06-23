import type { AgentMediaOutput } from "@inline-chat/agent-core"
import type { InputPeer } from "@inline-chat/protocol/core"
import { fetchBinary } from "@inline-chat/url-preview"
import { uploadPhoto } from "@in/server/modules/files/uploadPhoto"
import { Log } from "@in/server/utils/log"
import { sendInternalBotMessage } from "@in/server/modules/chatgpt/harness/messages"

const log = new Log("chatgpt.media")
const MAX_INLINE_MEDIA_BYTES = 20 * 1024 * 1024
const REMOTE_IMAGE_TYPES = ["image/jpeg", "image/png", "image/gif", "image/webp", "image/avif"]

export type ChatgptMediaSendResult = {
  readonly sent: boolean
  readonly outputMsgGlobalId?: bigint
}

export async function sendChatgptMediaOutput(input: {
  readonly media: AgentMediaOutput
  readonly inputPeer: InputPeer
  readonly actorUserId: number
  readonly botUserId: number
}): Promise<ChatgptMediaSendResult> {
  if (input.media.kind !== "image") {
    logUnsupportedMedia("unsupported_kind", input.media)
    return { sent: false }
  }

  if (input.media.bytes && input.media.bytes.byteLength > 0) {
    return sendGeneratedImage(input)
  }

  if (input.media.signedUrl) {
    return sendRemoteImage(input)
  }

  logUnsupportedMedia("provider_media_without_bytes", input.media)
  return { sent: false }
}

async function sendGeneratedImage(input: {
  readonly media: AgentMediaOutput
  readonly inputPeer: InputPeer
  readonly actorUserId: number
  readonly botUserId: number
}): Promise<ChatgptMediaSendResult> {
  const bytes = input.media.bytes
  if (!bytes || bytes.byteLength === 0) {
    return { sent: false }
  }

  if (bytes.byteLength > MAX_INLINE_MEDIA_BYTES) {
    logUnsupportedMedia("generated_image_too_large", input.media)
    return { sent: false }
  }

  try {
    const name = input.media.name?.trim() || "generated-image.png"
    const type = input.media.mimeType?.trim() || "image/png"
    const file = new File([bytes], name, { type })
    const result = await uploadPhoto(file, { userId: input.botUserId })
    if (!result.photoId) {
      logUnsupportedMedia("generated_image_upload_without_photo", input.media)
      return { sent: false }
    }

    const message = await sendInternalBotMessage({
      inputPeer: input.inputPeer,
      actorUserId: input.actorUserId,
      botUserId: input.botUserId,
      text: input.media.caption ?? "",
      media: {
        type: "photo",
        photoId: result.photoId,
      },
    })
    return { sent: true, outputMsgGlobalId: message.globalId }
  } catch (error) {
    log.warn("Failed to persist ChatGPT generated image output", {
      error,
      providerFileId: input.media.providerFileId,
      name: input.media.name,
      mimeType: input.media.mimeType,
      sizeBytes: bytes.byteLength,
    })
    return { sent: false }
  }
}

async function sendRemoteImage(input: {
  readonly media: AgentMediaOutput
  readonly inputPeer: InputPeer
  readonly actorUserId: number
  readonly botUserId: number
}): Promise<ChatgptMediaSendResult> {
  if (!input.media.signedUrl || !isHttpsUrl(input.media.signedUrl)) {
    logUnsupportedMedia("remote_image_url_not_https", input.media)
    return { sent: false }
  }

  try {
    const image = await fetchBinary(input.media.signedUrl, {
      maxBytes: MAX_INLINE_MEDIA_BYTES,
      allowedContentTypes: REMOTE_IMAGE_TYPES,
    })
    if (!image) {
      logUnsupportedMedia("remote_image_fetch_empty", input.media)
      return { sent: false }
    }

    return sendGeneratedImage({
      ...input,
      media: {
        ...input.media,
        bytes: image.bytes,
        mimeType: image.contentType,
        name: input.media.name ?? imageFileName(image.finalUrl, image.contentType),
        signedUrl: undefined,
      },
    })
  } catch (error) {
    log.warn("Failed to fetch ChatGPT image URL output", {
      error,
      ...urlLogMetadata(input.media.signedUrl),
      providerFileId: input.media.providerFileId,
      name: input.media.name,
      mimeType: input.media.mimeType,
    })
    return { sent: false }
  }
}

function logUnsupportedMedia(reason: string, media: AgentMediaOutput): void {
  log.warn("Unsupported ChatGPT media output", {
    reason,
    kind: media.kind,
    name: media.name,
    mimeType: media.mimeType,
    sizeBytes: media.bytes?.byteLength,
    hasSignedUrl: !!media.signedUrl,
    hasProviderFileId: !!media.providerFileId,
    ...(media.signedUrl ? urlLogMetadata(media.signedUrl) : {}),
  })
}

function isHttpsUrl(value: string): boolean {
  try {
    return new URL(value).protocol === "https:"
  } catch {
    return false
  }
}

function imageFileName(url: string, contentType: string): string {
  const name = fileNameFromUrl(url)
  if (name) {
    return name
  }

  switch (contentType) {
    case "image/jpeg":
      return "image.jpg"
    case "image/gif":
      return "image.gif"
    case "image/webp":
      return "image.webp"
    case "image/avif":
      return "image.avif"
    default:
      return "image.png"
  }
}

function fileNameFromUrl(value: string): string | undefined {
  try {
    const name = new URL(value).pathname.split("/").filter(Boolean).at(-1)
    return name ? decodeURIComponent(name).slice(0, 120) : undefined
  } catch {
    return undefined
  }
}

function urlLogMetadata(value: string): Record<string, unknown> {
  try {
    const url = new URL(value)
    return {
      urlProtocol: url.protocol,
      urlHost: url.hostname,
      urlPathExtension: url.pathname.match(/\.([a-z0-9]{1,8})$/i)?.[1]?.toLowerCase(),
    }
  } catch {
    return { urlInvalid: true }
  }
}
