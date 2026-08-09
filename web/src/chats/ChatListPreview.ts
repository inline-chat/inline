import type { Message, MessageDraft } from "@inline/client"

const compact = (value?: string, limit = 400) => {
  const text = value?.replaceAll(/\s+/g, " ").trim()
  if (!text) return undefined
  return text.length <= limit ? text : `${text.slice(0, limit - 1)}…`
}

const messageLabel = (message: Message) => {
  const text = compact(message.message)
  if (text) return text
  if (message.isSticker) return "Sticker"
  const media = message.media?.media
  switch (media?.oneofKind) {
    case "photo":
      return "Photo"
    case "video":
      return media.video.video?.isAnimated ? "Animation" : "Video"
    case "document":
      return compact(media.document.document?.fileName, 160) ?? "File"
    case "voice":
      return "Voice message"
    case "nudge":
      return "Nudge"
  }
  const attachment = message.attachments?.attachments.at(0)?.attachment
  if (attachment?.oneofKind === "externalTask") {
    return compact(attachment.externalTask.title, 160) ?? "Task"
  }
  if (attachment?.oneofKind === "urlPreview") {
    return compact(attachment.urlPreview.title, 160) ??
      compact(attachment.urlPreview.displayUrl, 160) ??
      "Link"
  }
  switch (message.serviceMessage?.event.oneofKind) {
    case "threadBacklink":
      return "Thread backlink"
    case "pinnedMessage":
      return "Pinned a message"
  }
  return "Unsupported message"
}

/** One bounded, nonblank preview contract shared by Inbox and All Chats. */
export const chatListPreview = ({
  message,
  draft,
  senderName,
  replyThread = false,
}: {
  message?: Message
  draft?: Pick<MessageDraft, "text">
  senderName?: string
  replyThread?: boolean
}) => {
  const draftText = compact(draft?.text)
  if (draftText) return `Draft: ${draftText}`
  if (!message) return replyThread ? "Reply · No messages" : "No messages"
  const senderPrefix = message.out
    ? "You: "
    : senderName
      ? `${compact(senderName, 80)}: `
      : ""
  const replyPrefix = replyThread ? "Reply · " : ""
  return `${replyPrefix}${senderPrefix}${messageLabel(message)}`
}
