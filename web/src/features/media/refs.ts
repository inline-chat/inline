/**
 * Which bytes a view asks for, as a core `MediaRef`, and the key two views
 * share them under. Pure.
 *
 * - A send from this device that is not on the server yet shows its local
 *   attachment (`attachment:<id>`): the bytes it is uploading.
 * - A message's photo shows the variant that covers its box at the pixel
 *   ratio (`chat-ui` `photoVariantFor`). Video and voice are whole files.
 * - The key is the server file and variant (`file:<fileUniqueId>:<variant>`),
 *   so two messages carrying the same file (a forward, a re-send) share one
 *   subscription and one URL. The core caches by that identity too
 *   (`assetForMessage`); a row without a `fileUniqueId` cannot be served by
 *   it, and the caller falls back to the row's signed URL.
 */

import { type Box, photoVariantFor } from "@inline/chat-ui"
import type { MediaRef, PhotoInfo, VideoInfo, VoiceInfo } from "@inline/core-protocol"
import type { MediaOwner } from "../content/sources"

export type MediaTarget = { readonly key: string; readonly ref: MediaRef }

export const attachmentKey = (attachmentId: string): string => `attachment:${attachmentId}`

/** The attachment a row shows instead of server bytes, if any. */
export const attachmentTarget = (owner: MediaOwner): MediaTarget | undefined =>
  owner.attachmentId !== undefined
    ? { key: attachmentKey(owner.attachmentId), ref: { kind: "attachment", attachmentId: owner.attachmentId } }
    : undefined

/** A message's photo (or a video's or document's thumbnail) on the server, for a box. */
export const photoTarget = (
  photo: PhotoInfo,
  box: Box,
  pixelRatio: number,
  owner: MediaOwner,
  thumbnail: boolean,
): MediaTarget | undefined => {
  if (owner.messageId === undefined) return undefined
  const variant = photoVariantFor(photo, box, pixelRatio)
  if (!variant) return undefined
  const size = variant.size.type
  const fileUniqueId = variant.size.fileUniqueId ?? photo.fileUniqueId
  if (!fileUniqueId) return undefined
  return {
    key: `file:${fileUniqueId}:${size}`,
    ref: {
      kind: "message",
      chatId: owner.chatId,
      messageId: owner.messageId,
      size,
      ...(thumbnail ? { thumbnail: true } : {}),
    },
  }
}

/** A message's whole file on the server: a video (GIFs play it), a voice note. */
export const fileTarget = (file: VideoInfo | VoiceInfo, owner: MediaOwner): MediaTarget | undefined => {
  if (owner.messageId === undefined || !file.fileUniqueId) return undefined
  return {
    key: `file:${file.fileUniqueId}:file`,
    ref: { kind: "message", chatId: owner.chatId, messageId: owner.messageId },
  }
}

/** A stable text form of a ref, for de-duplicating hints. */
export const refId = (ref: MediaRef): string =>
  ref.kind === "attachment"
    ? `a:${ref.attachmentId}`
    : `m:${ref.chatId}:${ref.messageId}:${ref.size ?? ""}:${ref.thumbnail ? 1 : 0}`
