/**
 * Which stored messages a `chatMedia` subscription lists: the server's
 * `SearchMessagesFilter` rules, applied to the device's messages.
 */
import { MessageEntity_Type } from "@inline-chat/protocol/core"
import type { ChatMediaFilter } from "@inline/core-protocol"
import type { Message } from "../database/models"

export const CHAT_MEDIA_FILTERS: readonly ChatMediaFilter[] = [
  "photosVideos",
  "photos",
  "videos",
  "files",
  "voice",
  "links",
]

/** Whether a stored message belongs in a `chatMedia` list (the server's filter rules). */
export const chatMediaMatches = (message: Message, filter: ChatMediaFilter): boolean => {
  const media = message.media?.media.oneofKind
  switch (filter) {
    case "photosVideos":
      return media === "photo" || media === "video"
    case "photos":
      return media === "photo"
    case "videos":
      return media === "video"
    case "files":
      return media === "document"
    case "voice":
      return media === "voice"
    case "links":
      return (
        message.hasLink === true ||
        (message.entities?.entities ?? []).some(
          (entity) => entity.type === MessageEntity_Type.URL || entity.type === MessageEntity_Type.TEXT_URL,
        ) ||
        (message.attachments?.attachments ?? []).some((attachment) => attachment.attachment.oneofKind === "urlPreview")
      )
  }
}

