import { Log } from "@in/server/utils/log"
import { isValidLoomUrl, fetchLoomOembed } from "@in/server/libs/loom"
import { encryptMessage } from "@in/server/modules/encryption/encryptMessage"
import { db } from "@in/server/db"
import { urlPreview, messageAttachments } from "@in/server/db/schema/attachments"
import { photos, type DbMessage } from "@in/server/db/schema"
import { uploadPhoto } from "../files/uploadPhoto"
import { eq } from "drizzle-orm"
import { InputPeer, Photo, MessageAttachment, UrlPreview_MediaType } from "@inline-chat/protocol/core"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { getUpdateGroupFromInputPeer } from "@in/server/modules/updates"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { processFullPhoto } from "@in/server/db/models/files"
import { encodeMessageAttachmentUpdate } from "@in/server/realtime/encoders/encodeMessageAttachment"
import sharp from "sharp"

const log = new Log("modules.loom")

type LoomMetadata = {
  url: string
  title: string
  description: string | null
  thumbnailUrl: string | null
  thumbnailWidth: number
  thumbnailHeight: number
  duration: number | null
  embedUrl: string | null
  embedWidth: number | null
  embedHeight: number | null
}

export async function processLoomLink(
  message: DbMessage,
  messageText: string,
  chatId: bigint,
  currentUserId: number,
  inputPeer: InputPeer,
): Promise<void> {
  try {
    // Find Loom links in the message
    const words = messageText.split(/\s+/)
    const loomUrl = words.find((word) => isValidLoomUrl(word))

    if (!loomUrl) return

    // Fetch Loom oEmbed data
    const oembed = await fetchLoomOembed(loomUrl)

    const metadata: LoomMetadata = {
      url: loomUrl,
      title: oembed.title,
      description: oembed.description || null,
      thumbnailUrl: oembed.thumbnailUrl || null,
      thumbnailWidth: oembed.thumbnailWidth,
      thumbnailHeight: oembed.thumbnailHeight,
      duration: oembed.duration == null ? null : Math.round(oembed.duration),
      embedUrl: extractIframeSrc(oembed.html) ?? null,
      embedWidth: oembed.width ?? null,
      embedHeight: oembed.height ?? null,
    }

    // Process the Loom link
    await processLoomMetadata(message, metadata, chatId, currentUserId, inputPeer)
  } catch (error) {
    log.error("Error processing Loom link", { error })
  }
}

async function processLoomMetadata(
  message: DbMessage,
  metadata: LoomMetadata,
  chatId: bigint,
  currentUserId: number,
  inputPeer: InputPeer,
): Promise<void> {
  try {
    // Encrypt sensitive data
    const urlEncrypted = encryptMessage(metadata.url)
    const titleEncrypted = encryptMessage(metadata.title)
    const descriptionEncrypted = metadata.description ? encryptMessage(metadata.description) : null
    const embedUrlEncrypted = metadata.embedUrl ? encryptMessage(metadata.embedUrl) : null

    // Download and save thumbnail
    let photoId: number | null = null
    if (metadata.thumbnailUrl) {
      photoId = await downloadAndSaveThumbnail(
        metadata.thumbnailUrl,
        metadata.thumbnailWidth,
        metadata.thumbnailHeight,
        currentUserId,
      )
    }

    // Create URL preview record
    const [urlPreviewRecord] = await db
      .insert(urlPreview)
      .values({
        url: urlEncrypted.encrypted,
        urlIv: urlEncrypted.iv,
        urlTag: urlEncrypted.authTag,
        siteName: "Loom",
        provider: "loom",
        mediaType: "video",
        mediaKind: "embed",
        title: titleEncrypted.encrypted,
        titleIv: titleEncrypted.iv,
        titleTag: titleEncrypted.authTag,
        description: descriptionEncrypted?.encrypted,
        descriptionIv: descriptionEncrypted?.iv,
        descriptionTag: descriptionEncrypted?.authTag,
        photoId: photoId,
        embedUrl: embedUrlEncrypted?.encrypted,
        embedUrlIv: embedUrlEncrypted?.iv,
        embedUrlTag: embedUrlEncrypted?.authTag,
        embedType: metadata.embedUrl ? "iframe" : null,
        embedWidth: metadata.embedWidth,
        embedHeight: metadata.embedHeight,
        embedDuration: metadata.duration,
        hasLargeMedia: true,
        showLargeMedia: true,
        duration: metadata.duration,
        date: new Date(),
      })
      .returning()
    if (!urlPreviewRecord) {
      log.error("Failed to create URL preview record")
      return
    }

    // Create link between message and URL preview
    const [attachment] = await db
      .insert(messageAttachments)
      .values({
        messageId: message.globalId,
        urlPreviewId: BigInt(urlPreviewRecord.id),
        externalTaskId: null,
      })
      .returning()

    if (!attachment) {
      log.error("Failed to create attachment record")
      return
    }

    // Create and send update
    await sendLoomUpdate(
      metadata,
      urlPreviewRecord.id,
      photoId,
      message,
      chatId,
      inputPeer,
      currentUserId,
      BigInt(attachment.id),
    )
  } catch (error) {
    log.error("Error processing Loom metadata", { error })
  }
}

async function downloadAndSaveThumbnail(
  url: string,
  width: number,
  height: number,
  currentUserId: number,
): Promise<number | null> {
  try {
    // Download image
    const response = await fetch(url)
    if (!response.ok) {
      log.error(`Failed to download thumbnail: ${response.status}`)
      return null
    }

    // Check Content-Type header for GIF or MJPEG
    const contentType = response.headers.get("content-type") || ""
    let imageBuffer = await response.arrayBuffer()
    let processedBuffer: Buffer | null = null
    let fileName = `loom_thumbnail_${Date.now()}.jpg`
    let fileType = "image/jpeg"

    if (
      contentType.includes("image/gif") ||
      contentType.includes("image/mjpeg") ||
      contentType.includes("multipart/x-mixed-replace")
    ) {
      // Convert to static JPEG using sharp (extract first frame)
      try {
        processedBuffer = await sharp(Buffer.from(imageBuffer)).jpeg().toBuffer()
        fileType = "image/jpeg"
        fileName = `loom_thumbnail_static_${Date.now()}.jpg`
      } catch (err) {
        log.error("Failed to convert animated image to static JPEG", { error: err })
        return null
      }
    } else {
      processedBuffer = Buffer.from(imageBuffer)
    }

    // Convert processedBuffer to File object
    const thumbnailFile = new File([processedBuffer], fileName, { type: fileType })

    // Upload photo to CDN and get photo ID
    const result = await uploadPhoto(thumbnailFile, { userId: currentUserId })
    return Number(result.photoId)
  } catch (error) {
    log.error("Error downloading thumbnail", { error })
    return null
  }
}

async function sendLoomUpdate(
  metadata: LoomMetadata,
  urlPreviewId: number,
  photoId: number | null,
  message: DbMessage,
  chatId: bigint,
  inputPeer: InputPeer,
  currentUserId: number,
  attachmentId: bigint,
): Promise<void> {
  try {
    // Get photo data if exists
    let protoPhoto: Photo | undefined
    if (photoId) {
      const photo = await db._query.photos.findFirst({
        where: eq(photos.id, photoId),
        with: {
          photoSizes: {
            with: {
              file: true,
            },
          },
        },
      })

      if (photo) {
        // TODO: Fix type cast
        protoPhoto = Encoders.photo({ photo: processFullPhoto(photo) })
      }
    }

    // Get update group for sending updates
    const updateGroup = await getUpdateGroupFromInputPeer(inputPeer, { currentUserId })

    // Create update message
    let attachment: MessageAttachment = {
      id: attachmentId,
      attachment: {
        oneofKind: "urlPreview",
        urlPreview: {
          id: BigInt(urlPreviewId),
          url: metadata.url,
          siteName: "Loom",
          title: metadata.title,
          description: metadata.description ?? undefined,
          photo: protoPhoto,
          duration: metadata.duration == null ? undefined : BigInt(metadata.duration),
          mediaType: UrlPreview_MediaType.VIDEO,
          provider: "loom",
          media:
            metadata.embedUrl == null
              ? undefined
              : {
                  media: {
                    oneofKind: "embed",
                    embed: {
                      url: metadata.embedUrl,
                      type: "iframe",
                      w: metadata.embedWidth ?? undefined,
                      h: metadata.embedHeight ?? undefined,
                      duration: metadata.duration ?? undefined,
                    },
                  },
                },
          layout: {
            hasLargeMedia: true,
            showLargeMedia: true,
          },
        },
      },
    }

    // Send updates to all relevant users
    if (updateGroup.type === "dmUsers") {
      updateGroup.userIds.forEach((userId: number) => {
        const encodingForUserId = userId
        const encodingForInputPeer: InputPeer =
          userId === currentUserId
            ? inputPeer
            : { type: { oneofKind: "user", user: { userId: BigInt(currentUserId) } } }

        let update = encodeMessageAttachmentUpdate({
          messageId: BigInt(message.messageId),
          chatId,
          encodingForUserId,
          encodingForPeer: { inputPeer: encodingForInputPeer },
          attachment,
        })

        RealtimeUpdates.pushToUser(userId, [update])
      })
    } else if (updateGroup.type === "threadUsers") {
      updateGroup.userIds.forEach((userId: number) => {
        const encodingForUserId = userId

        let update = encodeMessageAttachmentUpdate({
          messageId: BigInt(message.messageId),
          chatId,
          encodingForUserId,
          encodingForPeer: { inputPeer: inputPeer },
          attachment,
        })

        RealtimeUpdates.pushToUser(userId, [update])
      })
    }
  } catch (error) {
    log.error("Failed to send Loom update", { error })
  }
}

function extractIframeSrc(html: string | undefined): string | undefined {
  return html?.match(/<iframe\b[^>]*\bsrc=["']([^"']+)["']/i)?.[1]
}
