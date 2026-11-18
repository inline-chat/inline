/**
 * The media core inside the host: what a `media` subscription shows, the
 * claims it makes on the scheduler, nearby hints, and signed-URL refresh.
 *
 * Bytes reach the UI as a `Blob` handle in the subscription's resource (see
 * `MediaResource` in `core-protocol`): `MediaCache.read` returns a Blob backed
 * by the byte store (an OPFS file in the browser), and structured clone
 * carries the handle to the UI thread without copying the bytes. Cost per
 * image: one cache read (a file handle, no bytes read), one resource patch,
 * and on the UI side one object URL. While any subscription holds a file the
 * cache keeps it pinned (`viewer`), so the handle stays readable.
 */
import { UploadKind } from "@inline-chat/protocol/core"
import type {
  AttachmentInfo,
  MediaRef,
  MediaResource,
  UploadProgress,
} from "@inline/core-protocol"
import type { MessageID } from "@inline/ids"
import type { Log } from "@inline/log"
import {
  cacheId,
  type CacheKey,
  type DownloadHandle,
  type MediaAsset,
  type MediaCore,
  type MediaEvent,
  type UploadJobRecord,
} from "../media"
import { DbObjectKind, messageKey, type Message } from "../database/models"
import { mediaContent } from "../queries/content"
import type { ReplicaView } from "../queries/view"
import type { MediaContent, PhotoInfo } from "@inline/core-protocol"
import type { ChatID } from "@inline/ids"

type Claim = {
  ref: MediaRef
  opened: boolean
  key?: CacheKey
  asset?: MediaAsset
  download?: DownloadHandle
  unpin?: () => void
  resource: MediaResource
  /** Bumped on every resolve, so a late read for an older state is dropped. */
  generation: number
}

export type HostMediaOptions = {
  media: MediaCore
  /** Committed state: a message's media and its signed URLs. */
  view: ReplicaView
  /** What the attachment coordinator knows about a local attachment. */
  attachment: (attachmentId: string) => { info: AttachmentInfo; job?: UploadJobRecord; source?: () => Promise<Blob | undefined> } | undefined
  /** A message a subscription names is not resident: read it from disk (its arrival re-resolves). */
  want?: (messageKeys: readonly string[]) => void
  /** A subscription's resource changed. */
  onChange: (handle: number) => void
  log: Log
}

const largestPhotoSize = (photo: PhotoInfo) =>
  photo.sizes.reduce<PhotoInfo["sizes"][number] | undefined>(
    (best, size) => (!best || size.width * size.height > best.width * best.height ? size : best),
    undefined,
  )

/** The cacheable file a message's media names for a reference. */
export const assetForMessage = (
  media: MediaContent | undefined,
  ref: Extract<MediaRef, { kind: "message" }>,
): MediaAsset | undefined => {
  if (!media) return undefined
  const location = { chatId: BigInt(ref.chatId), messageId: BigInt(ref.messageId) }
  const photoAsset = (photo: PhotoInfo | undefined, kind: MediaAsset["kind"]): MediaAsset | undefined => {
    if (!photo) return undefined
    const size = ref.size ? photo.sizes.find((candidate) => candidate.type === ref.size) : largestPhotoSize(photo)
    const fileUniqueId = size?.fileUniqueId ?? photo.fileUniqueId
    if (!size || !fileUniqueId) return undefined
    return {
      key: { fileUniqueId, variant: size.type },
      kind,
      ...(size.size ? { sizeBytes: size.size } : {}),
      ...(size.cdnUrl ? { url: size.cdnUrl } : {}),
      message: location,
    }
  }
  const fileAsset = (
    file: { fileUniqueId?: string; cdnUrl?: string; size: number } | undefined,
    kind: MediaAsset["kind"],
  ): MediaAsset | undefined =>
    file?.fileUniqueId
      ? {
          key: { fileUniqueId: file.fileUniqueId, variant: "file" },
          kind,
          ...(file.size > 0 ? { sizeBytes: file.size } : {}),
          ...(file.cdnUrl ? { url: file.cdnUrl } : {}),
          message: location,
        }
      : undefined
  switch (media.kind) {
    case "photo":
      return photoAsset(media.photo, "media")
    case "video":
      return ref.thumbnail ? photoAsset(media.video.thumbnail, "media") : fileAsset(media.video, "media")
    case "document":
      return ref.thumbnail ? photoAsset(media.document.thumbnail, "media") : fileAsset(media.document, "file")
    case "voice":
      return fileAsset(media.voice, "voice")
    default:
      return undefined
  }
}

export const uploadProgress = (job: UploadJobRecord | undefined): UploadProgress | undefined => {
  if (!job) return undefined
  let sent = 0
  for (const index of job.acceptedParts) sent += Math.min(512 * 1024, job.byteCount - index * 512 * 1024)
  const state: UploadProgress["state"] =
    job.state === "finishing"
      ? "processing"
      : job.state === "paused"
        ? "uploading"
        : job.state
  return {
    state,
    sentBytes: job.state === "complete" ? job.byteCount : Math.min(sent, job.byteCount),
    totalBytes: job.byteCount,
    ...(job.state === "failed" ? { retryable: job.failure?.retryable !== false } : {}),
  }
}

export const uploadKindFor = (kind: AttachmentInfo["kind"]): UploadKind => {
  switch (kind) {
    case "photo":
      return UploadKind.PHOTO
    case "video":
      return UploadKind.VIDEO
    case "voice":
      return UploadKind.VOICE
    default:
      return UploadKind.DOCUMENT
  }
}

export class HostMedia {
  private readonly claims = new Map<number, Claim>()
  /** Nearby hints per context. */
  private readonly nearby = new Map<number, MediaAsset[]>()
  private readonly detach: () => void
  private closed = false

  constructor(private readonly options: HostMediaOptions) {
    this.detach = options.media.subscribe((event) => this.onEvent(event))
  }

  get core(): MediaCore {
    return this.options.media
  }

  resource(handle: number): MediaResource | undefined {
    return this.claims.get(handle)?.resource
  }

  /** A `media` subscription opened (or its reference changed). */
  open(handle: number, ref: MediaRef, priority: "visible" | "opened" = "visible") {
    this.close(handle)
    const claim: Claim = {
      ref,
      opened: priority === "opened",
      resource: { kind: "media", state: "absent" },
      generation: 0,
    }
    this.claims.set(handle, claim)
    void this.resolve(handle, claim)
  }

  close(handle: number) {
    const claim = this.claims.get(handle)
    if (!claim) return
    this.claims.delete(handle)
    this.release(claim)
  }

  /** The replica changed: references to messages whose media changed resolve again. */
  messagesChanged(keys: ReadonlySet<string>) {
    for (const [handle, claim] of this.claims) {
      if (claim.ref.kind !== "message") continue
      if (!keys.has(messageKey(claim.ref.chatId, claim.ref.messageId))) continue
      const asset = this.assetFor(claim.ref)
      // The same file (a refreshed URL, a reaction): the running download keeps going.
      if (asset && claim.key && cacheId(asset.key) === cacheId(claim.key) && claim.resource.state !== "absent") {
        claim.asset = asset
        continue
      }
      void this.resolve(handle, claim)
    }
  }

  /** An attachment's info or upload changed. */
  attachmentChanged(attachmentId: string) {
    for (const [handle, claim] of this.claims) {
      if (claim.ref.kind === "attachment" && claim.ref.attachmentId === attachmentId) void this.resolve(handle, claim)
    }
  }

  /** Replace one context's nearby set; the scheduler gets the union. */
  setNearby(context: number, refs: readonly MediaRef[]) {
    const assets = refs.flatMap((ref) => {
      if (ref.kind !== "message") return []
      const asset = this.assetFor(ref)
      return asset ? [asset] : []
    })
    if (assets.length === 0) this.nearby.delete(context)
    else this.nearby.set(context, assets)
    this.options.media.setNearby(Array.from(this.nearby.values()).flat())
  }

  dropContext(context: number) {
    if (this.nearby.delete(context)) this.options.media.setNearby(Array.from(this.nearby.values()).flat())
  }

  setOnline(online: boolean) {
    if (!this.closed) this.options.media.setOnline(online)
  }

  /**
   * After an expired signed URL was refreshed into the replica: the URL the
   * message now carries for the same file, if it changed.
   */
  freshUrl(asset: MediaAsset, stale: string, view: ReplicaView): string | undefined {
    const location = asset.message
    if (!location) return undefined
    const message = view.get(
      DbObjectKind.Message,
      messageKey(String(location.chatId) as ChatID, String(location.messageId) as MessageID),
    )
    const media = message?.media != null ? mediaContent(message.media, message.isSticker === true) : undefined
    const ref: Extract<MediaRef, { kind: "message" }> = {
      kind: "message",
      chatId: String(location.chatId) as ChatID,
      messageId: String(location.messageId) as MessageID,
      ...(asset.key.variant !== "file" ? { size: asset.key.variant } : {}),
    }
    const fresh = assetForMessage(media, ref) ?? assetForMessage(media, { ...ref, thumbnail: true })
    return fresh?.url && fresh.url !== stale && fresh.key.fileUniqueId === asset.key.fileUniqueId ? fresh.url : undefined
  }

  async stop(options: { erase: boolean }) {
    if (this.closed) return
    this.closed = true
    for (const claim of this.claims.values()) this.release(claim)
    this.claims.clear()
    this.detach()
    if (options.erase) await this.options.media.erase()
    else await this.options.media.close()
  }

  // -------------------------------------------------------------------------

  private assetFor(ref: Extract<MediaRef, { kind: "message" }>): MediaAsset | undefined {
    const message: Message | undefined = this.options.view.get(
      DbObjectKind.Message,
      messageKey(ref.chatId, ref.messageId),
    )
    if (!message?.media) return undefined
    try {
      return assetForMessage(mediaContent(message.media, message.isSticker === true), ref)
    } catch {
      return undefined
    }
  }

  private release(claim: Claim) {
    claim.download?.release()
    claim.download = undefined
    claim.unpin?.()
    claim.unpin = undefined
  }

  private set(handle: number, claim: Claim, resource: MediaResource) {
    if (this.claims.get(handle) !== claim) return
    claim.resource = resource
    this.options.onChange(handle)
  }

  private async resolve(handle: number, claim: Claim) {
    const generation = ++claim.generation
    const current = () => !this.closed && this.claims.get(handle) === claim && claim.generation === generation
    if (claim.ref.kind === "attachment") {
      const local = this.options.attachment(claim.ref.attachmentId)
      if (!local) {
        this.set(handle, claim, { kind: "media", state: "absent" })
        return
      }
      const blob = await local.source?.()
      if (!current()) return
      const upload = uploadProgress(local.job)
      this.set(handle, claim, {
        kind: "media",
        state: blob ? "ready" : "absent",
        ...(blob ? { blob, size: blob.size, mimeType: local.info.mimeType } : {}),
        attachment: local.info,
        ...(upload ? { upload } : {}),
      })
      return
    }
    const asset = this.assetFor(claim.ref)
    if (!asset) {
      const key = messageKey(claim.ref.chatId, claim.ref.messageId)
      if (!this.options.view.get(DbObjectKind.Message, key)) this.options.want?.([key])
      this.release(claim)
      this.set(handle, claim, { kind: "media", state: "absent" })
      return
    }
    let key: CacheKey
    try {
      cacheId(asset.key)
      key = asset.key
    } catch {
      this.set(handle, claim, { kind: "media", state: "failed", failure: "invalid" })
      return
    }
    const sameKey = claim.key && cacheId(claim.key) === cacheId(key)
    if (!sameKey) {
      this.release(claim)
      claim.key = key
      // Keep the file while this subscription shows it, so its Blob stays readable.
      claim.unpin = this.options.media.pin(key, "viewer")
    }
    claim.asset = asset
    const cache = this.options.media.cache
    if (cache.has(key)) {
      await this.showReady(handle, claim, generation)
      return
    }
    const scheduler = this.options.media.scheduler
    if (!claim.opened && !scheduler.allowsAuto(asset)) {
      this.set(handle, claim, { kind: "media", state: "absent" })
      return
    }
    claim.download?.release()
    claim.download = scheduler.request(asset, claim.opened ? "opened" : "visible")
    const status = scheduler.status(key)
    this.set(handle, claim, {
      kind: "media",
      state: status === "running" ? "downloading" : status === "failed" ? "failed" : "queued",
      ...(asset.sizeBytes ? { totalBytes: asset.sizeBytes } : {}),
    })
    claim.download.done.then(
      () => {
        if (current()) void this.showReady(handle, claim, generation)
      },
      (error: unknown) => {
        if (!current()) return
        const code = (error as { code?: string } | undefined)?.code
        if (code === "canceled" || code === "closed") return
        this.set(handle, claim, { kind: "media", state: "failed", failure: code ?? "network" })
      },
    )
  }

  private async showReady(handle: number, claim: Claim, generation: number) {
    const key = claim.key
    if (!key) return
    const blob = await this.options.media.read(key)
    if (this.closed || this.claims.get(handle) !== claim || claim.generation !== generation) return
    if (!blob) {
      // Evicted between the check and the read: fetch again.
      void this.resolve(handle, claim)
      return
    }
    this.set(handle, claim, {
      kind: "media",
      state: "ready",
      blob,
      size: blob.size,
      ...(blob.type ? { mimeType: blob.type } : {}),
    })
  }

  private onEvent(event: MediaEvent) {
    if (event.type !== "download-progress" && event.type !== "download-queued") return
    for (const [handle, claim] of this.claims) {
      if (!claim.key || cacheId(claim.key) !== event.id) continue
      if (claim.resource.state === "ready") continue
      if (event.type === "download-progress") {
        this.set(handle, claim, {
          kind: "media",
          state: "downloading",
          receivedBytes: event.receivedBytes,
          totalBytes: event.totalBytes,
        })
      }
    }
  }
}
