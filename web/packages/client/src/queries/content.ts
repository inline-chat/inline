/**
 * Pure mappers from the replica's stored message content (protobuf-ts shapes
 * from `@inline-chat/protocol/core`, round-tripped through msgpack) to the
 * plain content fields of `MessageRow` in `@inline/core-protocol`.
 *
 * Stored data is read defensively: every part is checked at runtime, and a
 * part that is missing, malformed or of an unknown kind degrades to an absent
 * field (or `{ kind: "unknown" }` where the UI needs to know something was
 * there). Nothing here throws. Byte arrays are copied, so a row never pins
 * the buffer a msgpack payload was decoded from.
 */
import {
  AgentGrantRequirement,
  BlockApproval_Subject,
  BlockCallout_Kind,
  BlockDecisionState,
  BlockDiff_Change,
  BlockDisclosure_ActivityKind,
  BlockDisclosure_Kind,
  BlockFormText_Kind,
  BlockList_Kind,
  BlockMeter_Tone,
  BlockReview_Verdict,
  BlockReviewFinding_Confidence,
  BlockReviewFinding_Outcome,
  BlockReviewFinding_Priority,
  BlockStatus as ProtoBlockStatus,
  BlockTable_Alignment,
  GridTranscriptMessageKind,
  MessageAction_Style,
  MessageAttachmentExternalTask_Status,
  MessageSubthread_Kind,
  Photo_Format,
  UrlPreview_MediaType,
  type BlockContent,
  type MessageSubthread,
  type MessageVia,
} from "@inline-chat/protocol/core"
import type {
  BlockImageInfo,
  BlockStatus,
  ContentBlock,
  DecisionState,
  DisclosureActivity,
  DocumentInfo,
  ExternalTaskStatus,
  FormField,
  FormInput,
  ForwardHeader,
  GrantRequirement,
  GridTranscriptEvent,
  MediaContent,
  MessageActionButton,
  MessageActionKind,
  MessageActionRows,
  MessageAttachmentContent,
  MessageRow,
  PeerRef,
  PhotoInfo,
  PhotoSizeInfo,
  RepliesSummary,
  ReviewFinding,
  ServiceContent,
  TableAlignment,
  TextRange,
  UrlPreviewAttachment,
  UrlPreviewMediaContent,
  UrlPreviewMediaType,
  VideoInfo,
  ViaInfo,
  VoiceInfo,
} from "@inline/core-protocol"
import {
  parseInlineId,
  type ChatID,
  type FileID,
  type InlineID,
  type MessageID,
  type PhotoID,
  type UserID,
} from "@inline/ids"
import type { Message } from "../database/models"

/**
 * Message fields the proto carries that the replica does not store yet
 * (`realtime/transactions/mappers.ts` `messageModel` drops them). They are
 * read when present so the rows fill in as soon as storage keeps them.
 *
 * TODO(storage): persist `blockContent`, `replyQuote`, `via` and `subthread`
 * on the stored `Message` (owned by core-hardening; reported, not changed here).
 */
export type StoredMessageExtras = {
  blockContent?: BlockContent
  replyQuote?: string
  via?: MessageVia
  subthread?: MessageSubthread
}

// ---------------------------------------------------------------------------
// Runtime readers

type Rec = Record<string, unknown>

const rec = (value: unknown): Rec | undefined =>
  value != null && typeof value === "object" && !Array.isArray(value) && !(value instanceof Uint8Array)
    ? (value as Rec)
    : undefined

const list = (value: unknown): readonly unknown[] => (Array.isArray(value) ? value : [])

/** A non-negative safe integer from a number or bigint. */
const count = (value: unknown): number | undefined => {
  const number = typeof value === "bigint" ? Number(value) : value
  return typeof number === "number" && Number.isSafeInteger(number) && number >= 0 ? number : undefined
}

const finite = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) ? value : undefined

const text = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined)

const nonEmpty = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined

const flag = (value: unknown): boolean | undefined => (typeof value === "boolean" ? value : undefined)

const bytes = (value: unknown): Uint8Array | undefined =>
  value instanceof Uint8Array && value.length > 0 ? value.slice() : undefined

const id = <K extends "user" | "chat" | "message" | "photo" | "file" | "inline">(
  value: unknown,
  positive = true,
): InlineID<K> | undefined =>
  typeof value === "number" || typeof value === "bigint" || typeof value === "string"
    ? parseInlineId<K>(value, { positive })
    : undefined

const userId = (value: unknown) => id<"user">(value) as UserID | undefined
const chatId = (value: unknown) => id<"chat">(value) as ChatID | undefined
const messageId = (value: unknown) => id<"message">(value) as MessageID | undefined

/** `[kind, payload]` of a protobuf-ts oneof; kind is undefined when unset. */
const oneof = (value: unknown): [string | undefined, unknown] => {
  const record = rec(value)
  const kind = typeof record?.oneofKind === "string" ? record.oneofKind : undefined
  return [kind, kind != null ? record?.[kind] : undefined]
}

/** Spread helper: `{ [key]: value }` when value is defined, else nothing. */
const opt = <K extends string, V>(key: K, value: V | undefined): { [P in K]?: V } =>
  (value === undefined ? {} : { [key]: value }) as { [P in K]?: V }

const enumValue = <T>(table: Partial<Record<number, T>>, value: unknown): T | undefined =>
  typeof value === "number" ? table[value] : undefined

/** Runs a mapper and turns a throw into `undefined`. Mappers should not throw; this is the backstop. */
const guard = <T>(map: () => T): T | undefined => {
  try {
    return map()
  } catch {
    return undefined
  }
}

// ---------------------------------------------------------------------------
// Peers

export const peerRef = (value: unknown): PeerRef | undefined => {
  const [kind, payload] = oneof(rec(value)?.type)
  if (kind === "chat") {
    const chat = chatId(rec(payload)?.chatId)
    return chat ? { kind: "chat", chatId: chat } : undefined
  }
  if (kind === "user") {
    const user = userId(rec(payload)?.userId)
    return user ? { kind: "user", userId: user } : undefined
  }
  return undefined
}

// ---------------------------------------------------------------------------
// Media

const photoFormat: Partial<Record<number, PhotoInfo["format"]>> = {
  [Photo_Format.JPEG]: "jpeg",
  [Photo_Format.PNG]: "png",
}

export const photoInfo = (value: unknown): PhotoInfo | undefined => {
  const photo = rec(value)
  const photoId = id<"photo">(photo?.id, false) as PhotoID | undefined
  if (!photo || !photoId) return undefined
  const sizes: PhotoSizeInfo[] = []
  let stripped: Uint8Array | undefined
  let fallbackStripped: Uint8Array | undefined
  for (const raw of list(photo.sizes)) {
    const size = rec(raw)
    if (!size) continue
    const type = text(size.type) ?? ""
    if (type === "s") {
      stripped ??= bytes(size.bytes)
      continue
    }
    fallbackStripped ??= bytes(size.bytes)
    const width = count(size.w)
    const height = count(size.h)
    if (width == null || height == null) continue
    const byteSize = count(size.size)
    sizes.push({
      type,
      width,
      height,
      ...opt("size", byteSize != null && byteSize > 0 ? byteSize : undefined),
      ...opt("fileUniqueId", nonEmpty(size.fileUniqueId)),
      ...opt("cdnUrl", nonEmpty(size.cdnUrl)),
    })
  }
  const date = count(photo.date)
  const thumb = stripped ?? fallbackStripped
  return {
    id: photoId,
    ...opt("date", date != null && date > 0 ? date : undefined),
    ...opt("format", enumValue(photoFormat, photo.format)),
    ...opt("fileUniqueId", nonEmpty(photo.fileUniqueId)),
    sizes,
    ...opt("stripped", thumb),
  }
}

const fileId = (value: unknown) => id<"file">(value, false) as FileID | undefined

const positiveDate = (value: unknown): number | undefined => {
  const date = count(value)
  return date != null && date > 0 ? date : undefined
}

export const videoInfo = (value: unknown): VideoInfo | undefined => {
  const video = rec(value)
  const videoId = fileId(video?.id)
  if (!video || !videoId) return undefined
  const thumbnail = photoInfo(video.photo)
  return {
    id: videoId,
    ...opt("date", positiveDate(video.date)),
    width: count(video.w) ?? 0,
    height: count(video.h) ?? 0,
    duration: count(video.duration) ?? 0,
    size: count(video.size) ?? 0,
    ...opt("thumbnail", thumbnail),
    ...opt("cdnUrl", nonEmpty(video.cdnUrl)),
    ...opt("fileUniqueId", nonEmpty(video.fileUniqueId)),
    ...(video.isAnimated === true ? { animated: true as const } : {}),
    ...opt("hasAudio", flag(video.hasAudio)),
  }
}

export const documentInfo = (value: unknown): DocumentInfo | undefined => {
  const document = rec(value)
  const documentId = fileId(document?.id)
  if (!document || !documentId) return undefined
  return {
    id: documentId,
    ...opt("date", positiveDate(document.date)),
    fileName: text(document.fileName) ?? "",
    mimeType: text(document.mimeType) ?? "",
    size: count(document.size) ?? 0,
    ...opt("thumbnail", photoInfo(document.photo)),
    ...opt("cdnUrl", nonEmpty(document.cdnUrl)),
    ...opt("fileUniqueId", nonEmpty(document.fileUniqueId)),
  }
}

export const voiceInfo = (value: unknown): VoiceInfo | undefined => {
  const voice = rec(value)
  const voiceId = fileId(voice?.id)
  if (!voice || !voiceId) return undefined
  return {
    id: voiceId,
    ...opt("date", positiveDate(voice.date)),
    duration: count(voice.duration) ?? 0,
    size: count(voice.size) ?? 0,
    mimeType: text(voice.mimeType) ?? "",
    ...opt("waveform", bytes(voice.waveform)),
    ...opt("cdnUrl", nonEmpty(voice.cdnUrl)),
    ...opt("fileUniqueId", nonEmpty(voice.fileUniqueId)),
  }
}

/** `MessageMedia` to `MediaContent`; undefined when unset, unknown or malformed. */
export const mediaContent = (value: unknown, sticker: boolean): MediaContent | undefined => {
  const [kind, payload] = oneof(rec(value)?.media)
  const inner = rec(payload)
  switch (kind) {
    case "photo": {
      const photo = photoInfo(inner?.photo)
      return photo ? { kind: "photo", photo, ...(sticker ? { sticker: true as const } : {}) } : undefined
    }
    case "video": {
      const video = videoInfo(inner?.video)
      return video ? { kind: "video", video, ...(sticker ? { sticker: true as const } : {}) } : undefined
    }
    case "document": {
      const document = documentInfo(inner?.document)
      return document ? { kind: "document", document } : undefined
    }
    case "voice": {
      const voice = voiceInfo(inner?.voice)
      return voice ? { kind: "voice", voice } : undefined
    }
    case "nudge":
      return { kind: "nudge" }
    default:
      return undefined
  }
}

// ---------------------------------------------------------------------------
// Attachments

const previewMediaType: Partial<Record<number, UrlPreviewMediaType>> = {
  [UrlPreview_MediaType.ARTICLE]: "article",
  [UrlPreview_MediaType.IMAGE]: "image",
  [UrlPreview_MediaType.VIDEO]: "video",
  [UrlPreview_MediaType.DOCUMENT]: "document",
  [UrlPreview_MediaType.EMBED]: "embed",
}

const taskStatus: Partial<Record<number, ExternalTaskStatus>> = {
  [MessageAttachmentExternalTask_Status.BACKLOG]: "backlog",
  [MessageAttachmentExternalTask_Status.TODO]: "todo",
  [MessageAttachmentExternalTask_Status.IN_PROGRESS]: "inProgress",
  [MessageAttachmentExternalTask_Status.DONE]: "done",
  [MessageAttachmentExternalTask_Status.CANCELLED]: "cancelled",
}

const positive = (value: unknown): number | undefined => {
  const number = count(value)
  return number != null && number > 0 ? number : undefined
}

const urlPreviewMedia = (value: unknown): UrlPreviewMediaContent | undefined => {
  const [kind, payload] = oneof(rec(value)?.media)
  const inner = rec(payload)
  switch (kind) {
    case "photo": {
      const photo = photoInfo(payload)
      return photo ? { kind: "photo", photo } : undefined
    }
    case "video": {
      const video = videoInfo(payload)
      return video ? { kind: "video", video } : undefined
    }
    case "document": {
      const document = documentInfo(payload)
      return document ? { kind: "document", document } : undefined
    }
    case "externalVideo":
    case "embed": {
      const url = nonEmpty(inner?.url)
      if (!inner || !url) return undefined
      const common = {
        url,
        ...opt("width", positive(inner.w)),
        ...opt("height", positive(inner.h)),
        ...opt("duration", positive(inner.duration)),
      }
      return kind === "externalVideo"
        ? { kind, ...common, ...opt("mimeType", nonEmpty(inner.mimeType)) }
        : { kind, ...common, ...opt("type", nonEmpty(inner.type)) }
    }
    default:
      return undefined
  }
}

const urlPreview = (attachmentId: InlineID, value: unknown): UrlPreviewAttachment | undefined => {
  const preview = rec(value)
  if (!preview) return undefined
  const layout = rec(preview.layout)
  return {
    kind: "urlPreview",
    id: attachmentId,
    ...opt("previewId", id<"inline">(preview.id) as InlineID | undefined),
    ...opt("url", nonEmpty(preview.url)),
    ...opt("displayUrl", nonEmpty(preview.displayUrl)),
    ...opt("siteName", nonEmpty(preview.siteName)),
    ...opt("title", nonEmpty(preview.title)),
    ...opt("description", nonEmpty(preview.description)),
    ...opt("provider", nonEmpty(preview.provider)),
    ...opt("author", nonEmpty(preview.author)),
    ...opt("iconEmoji", nonEmpty(preview.iconEmoji)),
    ...opt("duration", positive(preview.duration)),
    ...opt("mediaType", enumValue(previewMediaType, preview.mediaType)),
    ...opt("photo", photoInfo(preview.photo)),
    ...opt("authorPhoto", photoInfo(preview.authorPhoto)),
    ...opt("media", urlPreviewMedia(preview.media)),
    ...(layout
      ? { layout: { hasLargeMedia: layout.hasLargeMedia === true, showLargeMedia: layout.showLargeMedia === true } }
      : {}),
  }
}

const attachmentContent = (value: unknown): MessageAttachmentContent | undefined => {
  const attachment = rec(value)
  if (!attachment) return undefined
  const attachmentId = (id<"inline">(attachment.id, false) ?? "0") as InlineID
  const [kind, payload] = oneof(attachment.attachment)
  if (kind === "urlPreview") return urlPreview(attachmentId, payload) ?? { kind: "unknown", id: attachmentId }
  if (kind === "externalTask") {
    const task = rec(payload)
    if (!task) return { kind: "unknown", id: attachmentId }
    return {
      kind: "externalTask",
      id: attachmentId,
      ...opt("taskRecordId", id<"inline">(task.id) as InlineID | undefined),
      taskId: text(task.taskId) ?? "",
      application: text(task.application) ?? "",
      title: text(task.title) ?? "",
      ...opt("status", enumValue(taskStatus, task.status)),
      ...opt("assigneeUserId", userId(task.assignedUserId)),
      ...opt("url", nonEmpty(task.url)),
      ...opt("number", nonEmpty(task.number)),
      ...opt("date", positiveDate(task.date)),
    }
  }
  return { kind: "unknown", id: attachmentId }
}

export const attachmentsContent = (value: unknown): MessageAttachmentContent[] => {
  const result: MessageAttachmentContent[] = []
  for (const raw of list(rec(value)?.attachments)) {
    const attachment = guard(() => attachmentContent(raw))
    if (attachment) result.push(attachment)
  }
  return result
}

// ---------------------------------------------------------------------------
// Headers

export const forwardHeader = (value: unknown): ForwardHeader | undefined => {
  const header = rec(value)
  if (!header) return undefined
  const result: ForwardHeader = {
    ...opt("fromPeer", peerRef(header.fromPeerId)),
    ...opt("fromUserId", userId(header.fromId)),
    ...opt("fromMessageId", messageId(header.fromMessageId)),
  }
  return Object.keys(result).length > 0 ? result : undefined
}

const userIds = (value: unknown): UserID[] => {
  const result: UserID[] = []
  for (const raw of list(value)) {
    const user = userId(raw)
    if (user && !result.includes(user)) result.push(user)
  }
  return result
}

/** `MessageSubthread` first, as the Mac does, else `MessageReplies`. */
export const repliesSummary = (replies: unknown, subthread: unknown): RepliesSummary | undefined => {
  const sub = rec(subthread)
  const subChat = chatId(sub?.chatId)
  if (sub && subChat) {
    const kind = sub.kind === MessageSubthread_Kind.SUBTHREAD ? "subthread" : "reply"
    return {
      kind,
      chatId: subChat,
      count: count(sub.messageCount) ?? 0,
      hasUnread: sub.hasUnread === true,
      recentUserIds: userIds(sub.recentAuthorUserIds),
      ...opt("title", nonEmpty(text(sub.title)?.trim())),
    }
  }
  const reply = rec(replies)
  const replyChat = chatId(reply?.chatId)
  if (!reply || !replyChat) return undefined
  return {
    kind: "reply",
    chatId: replyChat,
    count: count(reply.replyCount) ?? 0,
    hasUnread: reply.hasUnread === true,
    recentUserIds: userIds(reply.recentReplierUserIds),
  }
}

export const viaInfo = (value: unknown): ViaInfo | undefined => {
  const via = rec(value)
  if (!via) return undefined
  const name = nonEmpty(via.name)
  const [kind, payload] = oneof(via.source)
  if (kind === "app" && typeof payload === "string") return { kind: "app", app: payload, ...opt("name", name) }
  if (kind === "botUserId") {
    const bot = userId(payload)
    return bot ? { kind: "bot", botUserId: bot, ...opt("name", name) } : undefined
  }
  return undefined
}

// ---------------------------------------------------------------------------
// Service

const transcriptEvent: Partial<Record<number, GridTranscriptEvent>> = {
  [GridTranscriptMessageKind.GRID_TRANSCRIPT_TURN]: "turn",
  [GridTranscriptMessageKind.GRID_TRANSCRIPT_STARTED]: "started",
  [GridTranscriptMessageKind.GRID_TRANSCRIPT_STOPPED]: "stopped",
  [GridTranscriptMessageKind.GRID_TRANSCRIPT_INTERRUPTED]: "interrupted",
  [GridTranscriptMessageKind.GRID_TRANSCRIPT_LINK]: "link",
}

export const serviceContent = (value: unknown): ServiceContent | undefined => {
  const service = rec(value)
  if (!service) return undefined
  const [kind, payload] = oneof(service.event)
  const event = rec(payload)
  if (kind === "threadBacklink" && event) {
    return {
      kind: "threadBacklink",
      ...opt("sourceChatId", chatId(event.sourceChatId)),
      ...opt("sourceTitle", nonEmpty(event.sourceTitle)),
    }
  }
  if (kind === "pinnedMessage" && event) {
    return { kind: "pinnedMessage", ...opt("messageId", messageId(event.messageId)) }
  }
  if (kind === "gridTranscript" && event) {
    return {
      kind: "gridTranscript",
      runId: text(event.runId) ?? "",
      segmentId: text(event.segmentId) ?? "",
      ...opt("speakerUserId", userId(event.speakerUserId)),
      // proto3 default: an absent kind is TURN (0).
      event: enumValue(transcriptEvent, event.kind ?? 0) ?? "turn",
    }
  }
  return { kind: "unknown" }
}

// ---------------------------------------------------------------------------
// Bot buttons

const grantTable: Partial<Record<number, GrantRequirement>> = {
  [AgentGrantRequirement.ACCESS]: "access",
  [AgentGrantRequirement.INVOKE]: "invoke",
  [AgentGrantRequirement.STEER]: "steer",
  [AgentGrantRequirement.APPROVE]: "approve",
  [AgentGrantRequirement.CONFIGURE]: "configure",
  [AgentGrantRequirement.OWNER]: "owner",
}

/** Absent for none; `unknown` for a value this build does not know. */
const grant = (value: unknown): GrantRequirement | undefined => {
  if (typeof value !== "number" || value === AgentGrantRequirement.NONE) return undefined
  return grantTable[value] ?? "unknown"
}

const actionStyle: Partial<Record<number, MessageActionButton["style"]>> = {
  [MessageAction_Style.PRIMARY]: "primary",
  [MessageAction_Style.DESTRUCTIVE]: "destructive",
}

const actionKind = (value: unknown): MessageActionKind => {
  const [kind, payload] = oneof(value)
  const inner = rec(payload)
  switch (kind) {
    case "callback":
      return { kind: "callback" }
    case "copyText": {
      const copy = text(inner?.text)
      return copy != null ? { kind: "copyText", text: copy } : { kind: "unknown" }
    }
    case "openUrl": {
      const url = text(inner?.url)
      return url != null ? { kind: "openUrl", url } : { kind: "unknown" }
    }
    case "openLink": {
      const peer = peerRef(inner?.peerId)
      return peer
        ? { kind: "openLink", peer, ...opt("messageId", messageId(inner?.messageId)) }
        : { kind: "unknown" }
    }
    case "compose": {
      const compose = text(inner?.text)
      return compose != null ? { kind: "compose", text: compose } : { kind: "unknown" }
    }
    default:
      return { kind: "unknown" }
  }
}

const actionButton = (value: unknown): MessageActionButton | undefined => {
  const action = rec(value)
  const actionId = text(action?.actionId)
  if (!action || actionId == null) return undefined
  const confirm = rec(action.confirm)
  return {
    actionId,
    text: text(action.text) ?? "",
    style: enumValue(actionStyle, action.style) ?? "default",
    action: actionKind(action.action),
    ...(confirm
      ? {
          confirm: {
            title: text(confirm.title) ?? "",
            ...opt("text", nonEmpty(confirm.text)),
            ...opt("confirmText", nonEmpty(confirm.confirmText)),
          },
        }
      : {}),
    ...opt("requiredGrant", grant(action.requiredGrant)),
  }
}

export const actionRows = (value: unknown): MessageActionRows => {
  const rows: MessageActionRows = []
  for (const rawRow of list(rec(value)?.rows)) {
    const row: MessageActionButton[] = []
    for (const raw of list(rec(rawRow)?.actions)) {
      const button = guard(() => actionButton(raw))
      if (button) row.push(button)
    }
    if (row.length > 0) rows.push(row)
  }
  return rows
}

// ---------------------------------------------------------------------------
// Blocks

/** Deeper nesting than this is projected as `unknown`; the render model's own limit is lower. */
export const MAX_PROJECTED_BLOCK_DEPTH = 32

const blockStatus: Partial<Record<number, BlockStatus>> = {
  [ProtoBlockStatus.PENDING]: "pending",
  [ProtoBlockStatus.RUNNING]: "running",
  [ProtoBlockStatus.WAITING]: "waiting",
  [ProtoBlockStatus.DONE]: "done",
  [ProtoBlockStatus.FAILED]: "failed",
  [ProtoBlockStatus.CANCELLED]: "cancelled",
}

const decisionState: Partial<Record<number, DecisionState>> = {
  [BlockDecisionState.PENDING]: "pending",
  [BlockDecisionState.ACCEPTED]: "accepted",
  [BlockDecisionState.DECLINED]: "declined",
  [BlockDecisionState.EXPIRED]: "expired",
  [BlockDecisionState.SUPERSEDED]: "superseded",
}

const activityKind: Partial<Record<number, DisclosureActivity>> = {
  [BlockDisclosure_ActivityKind.REASONING]: "reasoning",
  [BlockDisclosure_ActivityKind.EXPLORE]: "explore",
  [BlockDisclosure_ActivityKind.READ]: "read",
  [BlockDisclosure_ActivityKind.SEARCH]: "search",
  [BlockDisclosure_ActivityKind.EDIT]: "edit",
  [BlockDisclosure_ActivityKind.DELETE]: "delete",
  [BlockDisclosure_ActivityKind.MOVE]: "move",
  [BlockDisclosure_ActivityKind.COMMAND]: "command",
  [BlockDisclosure_ActivityKind.WEB]: "web",
  [BlockDisclosure_ActivityKind.TOOL]: "tool",
  [BlockDisclosure_ActivityKind.AGENT]: "agent",
}

const alignment: Partial<Record<number, TableAlignment>> = {
  [BlockTable_Alignment.LEFT]: "left",
  [BlockTable_Alignment.CENTER]: "center",
  [BlockTable_Alignment.RIGHT]: "right",
}

const diffChange: Partial<Record<number, NonNullable<Extract<ContentBlock, { kind: "diff" }>["change"]>>> = {
  [BlockDiff_Change.ADDED]: "added",
  [BlockDiff_Change.MODIFIED]: "modified",
  [BlockDiff_Change.DELETED]: "deleted",
  [BlockDiff_Change.RENAMED]: "renamed",
}

const calloutTone: Partial<Record<number, NonNullable<Extract<ContentBlock, { kind: "callout" }>["tone"]>>> = {
  [BlockCallout_Kind.INFO]: "info",
  [BlockCallout_Kind.SUCCESS]: "success",
  [BlockCallout_Kind.WARNING]: "warning",
  [BlockCallout_Kind.ERROR]: "error",
}

const meterTone: Partial<Record<number, "warning" | "critical">> = {
  [BlockMeter_Tone.WARNING]: "warning",
  [BlockMeter_Tone.CRITICAL]: "critical",
}

const approvalSubject: Partial<
  Record<number, NonNullable<Extract<ContentBlock, { kind: "approval" }>["subject"]>>
> = {
  [BlockApproval_Subject.COMMAND]: "command",
  [BlockApproval_Subject.FILE_CHANGE]: "fileChange",
  [BlockApproval_Subject.TOOL]: "tool",
  [BlockApproval_Subject.PERMISSIONS]: "permissions",
  [BlockApproval_Subject.NETWORK]: "network",
}

const verdict: Partial<Record<number, NonNullable<Extract<ContentBlock, { kind: "review" }>["verdict"]>>> = {
  [BlockReview_Verdict.CORRECT]: "correct",
  [BlockReview_Verdict.INCORRECT]: "incorrect",
  [BlockReview_Verdict.NEEDS_ATTENTION]: "needsAttention",
}

const priority: Partial<Record<number, NonNullable<ReviewFinding["priority"]>>> = {
  [BlockReviewFinding_Priority.P0]: "p0",
  [BlockReviewFinding_Priority.P1]: "p1",
  [BlockReviewFinding_Priority.P2]: "p2",
  [BlockReviewFinding_Priority.P3]: "p3",
}

const confidence: Partial<Record<number, NonNullable<ReviewFinding["confidence"]>>> = {
  [BlockReviewFinding_Confidence.CONFIRMED]: "confirmed",
  [BlockReviewFinding_Confidence.PLAUSIBLE]: "plausible",
}

const outcome: Partial<Record<number, NonNullable<ReviewFinding["outcome"]>>> = {
  [BlockReviewFinding_Outcome.FIXED]: "fixed",
  [BlockReviewFinding_Outcome.SKIPPED]: "skipped",
  [BlockReviewFinding_Outcome.NO_CHANGE_NEEDED]: "noChangeNeeded",
}

/** `BlockText` to a range; undefined when offset or length is not a non-negative safe integer. */
export const textRange = (value: unknown): TextRange | undefined => {
  const range = rec(value)
  const offset = count(range?.offset)
  const length = count(range?.length)
  if (offset == null || length == null) return undefined
  const rtl = flag(range?.isRtl)
  return { offset, length, ...opt("rtl", rtl) }
}

const rtlOf = (record: Rec) => opt("rtl", flag(record.isRtl))

const stringList = (value: unknown): string[] => {
  const result: string[] = []
  for (const raw of list(value)) if (typeof raw === "string") result.push(raw)
  return result
}

const blockImage = (value: unknown): BlockImageInfo => {
  const image = rec(value)
  const alt = textRange(image?.alt)
  const [kind, payload] = oneof(image?.state)
  const base = opt("alt", alt)
  if (kind === "ready") {
    const photo = photoInfo(payload)
    return photo ? { ...base, state: "ready", photo } : { ...base, state: "unknown" }
  }
  if (kind === "pending" || kind === "unavailable") {
    const inner = rec(payload)
    const dimensions = rec(inner?.dimensions)
    const width = positive(dimensions?.width)
    const height = positive(dimensions?.height)
    return {
      ...base,
      state: kind,
      ...(width != null && height != null ? { width, height } : {}),
      ...(kind === "pending" ? opt("stripped", bytes(inner?.strippedThumbnail)) : {}),
    }
  }
  return { ...base, state: "unknown" }
}

const formInput = (field: Rec): FormInput => {
  const [kind, payload] = oneof(field.kind)
  const input = rec(payload)
  if (!input) return { kind: "unknown" }
  switch (kind) {
    case "select": {
      const options = list(input.options).flatMap((raw) => {
        const option = rec(raw)
        const optionId = text(option?.optionId)
        if (!option || optionId == null) return []
        return [
          {
            optionId,
            ...opt("label", textRange(option.label)),
            ...opt("description", textRange(option.description)),
            ...opt("preview", textRange(option.preview)),
            recommended: option.recommended === true,
          },
        ]
      })
      return {
        kind: "select",
        options,
        multiple: input.multiple === true,
        defaultOptionIds: stringList(input.defaultOptionIds),
        allowOther: input.allowOther === true,
      }
    }
    case "text": {
      const style =
        input.kind === BlockFormText_Kind.SECRET
          ? "secret"
          : input.kind === BlockFormText_Kind.MULTILINE
            ? "multiline"
            : "singleLine"
      const maxLength = positive(input.maxLength)
      return {
        kind: "text",
        style,
        ...opt("placeholder", nonEmpty(input.placeholder)),
        // A secret field never carries a default, whatever the sender put there.
        ...(style === "secret" ? {} : opt("defaultValue", text(input.defaultValue))),
        ...opt("maxLength", maxLength),
      }
    }
    case "toggle":
      return { kind: "toggle", defaultValue: input.defaultValue === true }
    case "number":
      return {
        kind: "number",
        ...opt("defaultValue", finite(input.defaultValue)),
        ...opt("min", finite(input.min)),
        ...opt("max", finite(input.max)),
        ...opt("step", finite(input.step)),
        integer: input.integer === true,
      }
    default:
      return { kind: "unknown" }
  }
}

const formFields = (value: unknown): FormField[] =>
  list(value).flatMap((raw) => {
    const field = rec(raw)
    const fieldId = text(field?.fieldId)
    if (!field || fieldId == null) return []
    return [
      {
        fieldId,
        ...opt("label", textRange(field.label)),
        ...opt("description", textRange(field.description)),
        ...opt("header", textRange(field.header)),
        required: field.required === true,
        input: formInput(field),
      },
    ]
  })

const reviewFindings = (value: unknown): ReviewFinding[] =>
  list(value).flatMap((raw) => {
    const finding = rec(raw)
    if (!finding) return []
    return [
      {
        ...opt("title", textRange(finding.title)),
        ...opt("body", textRange(finding.body)),
        ...opt("priority", enumValue(priority, finding.priority)),
        ...opt("path", textRange(finding.path)),
        ...opt("startLine", positive(finding.startLine)),
        ...opt("endLine", positive(finding.endLine)),
        ...opt("category", nonEmpty(finding.category)),
        ...opt("confidence", enumValue(confidence, finding.confidence)),
        ...opt("outcome", enumValue(outcome, finding.outcome)),
        ...opt("actionId", nonEmpty(finding.actionId)),
      },
    ]
  })

const children = (value: unknown, depth: number): ContentBlock[] =>
  list(value).map((raw) => contentBlock(raw, depth + 1))

const unknownBlock: ContentBlock = { kind: "unknown" }

/** One `Block`. Never throws; anything it cannot read is `{ kind: "unknown" }`. */
export const contentBlock = (value: unknown, depth = 0): ContentBlock => {
  if (depth >= MAX_PROJECTED_BLOCK_DEPTH) return { kind: "unknown" }
  return guard(() => blockOf(value, depth)) ?? { kind: "unknown" }
}

const blockOf = (value: unknown, depth: number): ContentBlock => {
  const [kind, payload] = oneof(rec(value)?.kind)
  const block = rec(payload)
  if (!block) return kind === "separator" ? { kind: "separator" } : unknownBlock
  switch (kind) {
    case "paragraph":
    case "footer":
    case "math":
      return { kind, ...opt("text", textRange(block)) }
    case "heading":
      return { kind, ...opt("text", textRange(block.text)), level: count(block.level) ?? 1 }
    case "code":
      return { kind, ...opt("text", textRange(block.text)), ...opt("language", nonEmpty(block.language)) }
    case "list": {
      const style: "ordered" | "unordered" | undefined =
        block.kind === BlockList_Kind.ORDERED ? "ordered" : block.kind === BlockList_Kind.UNORDERED ? "unordered" : undefined
      const start = typeof block.start === "bigint" || typeof block.start === "number" ? Number(block.start) : undefined
      return {
        kind,
        ...opt("style", style),
        ...opt("start", start != null && Number.isSafeInteger(start) ? start : undefined),
        items: list(block.items).map((raw) => {
          const item = rec(raw)
          return { children: children(item?.children, depth), ...opt("checked", flag(item?.checked)) }
        }),
        ...rtlOf(block),
      }
    }
    case "separator":
      return { kind }
    case "image":
      return { kind, image: blockImage(block) }
    case "album":
      return { kind, images: list(block.images).map(blockImage) }
    case "disclosure":
      return {
        kind,
        ...opt("summary", textRange(block.summary)),
        style: block.kind === BlockDisclosure_Kind.PROGRESS ? "progress" : "default",
        ...opt("initiallyOpen", flag(block.initiallyOpen)),
        children: children(block.children, depth),
        ...rtlOf(block),
        ...opt("activity", enumValue(activityKind, block.activityKind)),
        ...opt("status", enumValue(blockStatus, block.status)),
        ...opt("meta", textRange(block.meta)),
        ...opt("startedAt", positive(block.startedAt)),
      }
    case "quote":
      return { kind, children: children(block.children, depth), ...rtlOf(block) }
    case "table":
      return {
        kind,
        rows: list(block.rows).map((raw) =>
          list(rec(raw)?.cells).map((cell) => textRange(cell) ?? { offset: 0, length: 0 }),
        ),
        alignments: list(block.alignments).map((raw) => enumValue(alignment, raw)),
        ...rtlOf(block),
      }
    case "diff":
      return {
        kind,
        ...opt("path", textRange(block.path)),
        ...opt("text", textRange(block.text)),
        ...opt("change", enumValue(diffChange, block.change)),
        ...opt("previousPath", textRange(block.previousPath)),
        ...opt("additions", count(block.additions)),
        ...opt("deletions", count(block.deletions)),
        ...opt("language", nonEmpty(block.language)),
        ...opt("truncated", flag(block.truncated)),
      }
    case "fields":
      return {
        kind,
        fields: list(block.fields).flatMap((raw) => {
          const field = rec(raw)
          if (!field) return []
          return [
            {
              ...opt("label", textRange(field.label)),
              ...opt("value", textRange(field.value)),
              monospace: field.monospace === true,
            },
          ]
        }),
        ...rtlOf(block),
      }
    case "steps":
      return {
        kind,
        steps: list(block.steps).flatMap((raw) => {
          const step = rec(raw)
          if (!step) return []
          return [
            {
              ...opt("text", textRange(step.text)),
              ...opt("status", enumValue(blockStatus, step.status)),
              ...opt("detail", textRange(step.detail)),
            },
          ]
        }),
        ...rtlOf(block),
      }
    case "callout":
      return {
        kind,
        ...opt("tone", enumValue(calloutTone, block.kind)),
        ...opt("title", textRange(block.title)),
        children: children(block.children, depth),
        ...rtlOf(block),
      }
    case "meter":
      return {
        kind,
        ...opt("label", textRange(block.label)),
        value: finite(block.value) ?? 0,
        max: finite(block.max) ?? 0,
        ...opt("meta", textRange(block.meta)),
        ...opt("tone", enumValue(meterTone, block.tone)),
      }
    case "form":
      return {
        kind,
        formId: text(block.formId) ?? "",
        ...opt("title", textRange(block.title)),
        fields: formFields(block.fields),
        ...opt("submitLabel", nonEmpty(block.submitLabel)),
        ...opt("requiredGrant", grant(block.requiredGrant)),
        closed: block.closed === true,
        ...rtlOf(block),
      }
    case "widget": {
      const height = positive(block.height)
      return {
        kind,
        widgetId: text(block.widgetId) ?? "",
        ...opt("title", textRange(block.title)),
        htmlLength: typeof block.html === "string" ? block.html.length : 0,
        ...opt("height", height),
        images: list(block.images).map(blockImage),
        ...opt("requiredGrant", grant(block.requiredGrant)),
      }
    }
    case "planProposal":
      return {
        kind,
        ...opt("title", textRange(block.title)),
        children: children(block.children, depth),
        ...opt("state", enumValue(decisionState, block.state)),
        actionIds: stringList(block.actionIds),
        ...opt("decidedByUserId", userId(block.decidedByUserId)),
        ...rtlOf(block),
      }
    case "approval":
      return {
        kind,
        ...opt("subject", enumValue(approvalSubject, block.subject)),
        ...opt("title", textRange(block.title)),
        ...opt("command", textRange(block.command)),
        ...opt("cwd", textRange(block.cwd)),
        ...opt("reason", textRange(block.reason)),
        children: children(block.children, depth),
        ...opt("state", enumValue(decisionState, block.state)),
        actionIds: stringList(block.actionIds),
        ...opt("decidedByUserId", userId(block.decidedByUserId)),
        ...rtlOf(block),
      }
    case "review":
      return {
        kind,
        ...opt("title", textRange(block.title)),
        ...opt("verdict", enumValue(verdict, block.verdict)),
        ...opt("summary", textRange(block.summary)),
        findings: reviewFindings(block.findings),
        ...rtlOf(block),
      }
    case "taskSuggestion":
      return {
        kind,
        ...opt("title", textRange(block.title)),
        ...opt("brief", textRange(block.brief)),
        ...opt("state", enumValue(decisionState, block.state)),
        ...opt("startedPeer", peerRef(block.startedPeer)),
        ...opt("expiresAt", positive(block.expiresAt)),
        actionIds: stringList(block.actionIds),
        ...rtlOf(block),
      }
    case "nextStep":
      return {
        kind,
        ...opt("recap", textRange(block.recap)),
        ...opt("question", textRange(block.question)),
        actionIds: stringList(block.actionIds),
        blocking: block.blocking === true,
        ...rtlOf(block),
      }
    case "promptSuggestions":
      return {
        kind,
        prompts: list(block.prompts).flatMap((raw) => {
          const prompt = rec(raw)
          if (!prompt) return []
          return [{ ...opt("label", textRange(prompt.label)), ...opt("text", nonEmpty(prompt.text)) }]
        }),
        ...rtlOf(block),
      }
    default:
      return unknownBlock
  }
}

export const contentBlocks = (value: unknown): ContentBlock[] =>
  list(rec(value)?.blocks).map((raw) => contentBlock(raw))

// ---------------------------------------------------------------------------
// The message

export type MessageContentFields = Pick<
  MessageRow,
  | "media"
  | "groupedId"
  | "attachments"
  | "forward"
  | "replyQuote"
  | "replies"
  | "via"
  | "service"
  | "actions"
  | "blocks"
>

/**
 * The content fields of a message row, and whether something stored could
 * not be represented (`MessageRow.hasUnsupportedContent`).
 */
export const messageContent = (
  message: Message & StoredMessageExtras,
): { fields: MessageContentFields; unsupported: boolean } => {
  let unsupported = false
  const media = message.media != null ? guard(() => mediaContent(message.media, message.isSticker === true)) : undefined
  if (message.media != null && media == null) unsupported = true
  const attachments = message.attachments != null ? (guard(() => attachmentsContent(message.attachments)) ?? []) : []
  if (attachments.some((attachment) => attachment.kind === "unknown")) unsupported = true
  if (message.attachments != null && list(rec(message.attachments)?.attachments).length !== attachments.length) {
    unsupported = true
  }
  const service = message.serviceMessage != null ? guard(() => serviceContent(message.serviceMessage)) : undefined
  if (message.serviceMessage != null && (service == null || service.kind === "unknown")) unsupported = true
  const actions = message.actions != null ? (guard(() => actionRows(message.actions)) ?? []) : []
  if (actions.some((row) => row.some((button) => button.action.kind === "unknown"))) unsupported = true
  const blocks = message.blockContent != null ? (guard(() => contentBlocks(message.blockContent)) ?? []) : []
  const forward = message.fwdFrom != null ? guard(() => forwardHeader(message.fwdFrom)) : undefined
  const replies =
    message.replies != null || message.subthread != null
      ? guard(() => repliesSummary(message.replies, message.subthread))
      : undefined
  const via = message.via != null ? guard(() => viaInfo(message.via)) : undefined
  const groupedId = id<"inline">(message.groupedId)
  const fields: MessageContentFields = {
    ...opt("media", media),
    ...opt("groupedId", groupedId as string | undefined),
    ...(attachments.length > 0 ? { attachments } : {}),
    ...opt("forward", forward),
    ...opt("replyQuote", nonEmpty(message.replyQuote)),
    ...opt("replies", replies),
    ...opt("via", via),
    ...opt("service", service),
    ...(actions.length > 0 ? { actions } : {}),
    ...(blocks.length > 0 ? { blocks } : {}),
  }
  return { fields, unsupported }
}

