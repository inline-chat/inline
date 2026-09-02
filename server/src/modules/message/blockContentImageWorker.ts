import { randomUUID } from "node:crypto"
import { BlockImage, MessageEntity_Type, type Update } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import type { Transaction } from "@in/server/db/types"
import { FileModel } from "@in/server/db/models/files"
import { MessageModel } from "@in/server/db/models/messages"
import { UpdatesModel, type UpdateSeqAndDate } from "@in/server/db/models/updates"
import {
  blockContentImageJobs,
  blockContents,
  chats,
  files,
  messages,
  photos,
  photoSizes,
  threadGraphLinks,
  type DbBlockContentImageJob,
} from "@in/server/db/schema"
import { UpdateBucket } from "@in/server/db/schema/updates"
import { isTest } from "@in/server/env"
import { decrypt, encrypt } from "@in/server/modules/encryption/encryption"
import type { FileObjectIdentity } from "@in/server/modules/files/uploadAFile"
import { FILES_PATH_PREFIX } from "@in/server/modules/files/path"
import { uploadPhoto } from "@in/server/modules/files/uploadPhoto"
import { deleteFromBucket } from "@in/server/modules/files/uploadToBucket"
import { getUpdateGroupFromInputPeer } from "@in/server/modules/updates"
import { getMessageThreadProjectionsMap } from "@in/server/modules/subthreads"
import { queueMessageThreadLinkMaterialization } from "@in/server/modules/threadGraph"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { encodeDateStrict } from "@in/server/realtime/encoders/helpers"
import { encodePeerFromChat } from "@in/server/realtime/encoders/encodePeer"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { toArrayBufferBackedBytes } from "@in/server/utils/arrayBuffer"
import { Log } from "@in/server/utils/log"
import { and, asc, eq, gt, inArray, isNotNull, isNull, lte, not, or, sql } from "drizzle-orm"
import {
  getBlockImageAtPath,
  replaceBlockImageAtPath,
  validateBlockContent,
} from "./blockContent"
import {
  assertStoredBlockContentPayloadFits,
  decryptStoredBlockContent,
  encryptStoredBlockContent,
  StoredBlockContentPayloadError,
} from "./blockContentPayload"
import { downloadBlockImage, RemoteBlockImageError } from "./blockContentRemoteImage"
import { deleteUnreferencedBlockContents } from "./blockContentStorage"

const log = new Log("blockContent.imageWorker")
const pollIntervalMs = 1_500
const leaseMs = 60_000
const leaseHeartbeatMs = 20_000
const maxAttempts = 5
const batchSize = 4

type ClaimedJob = DbBlockContentImageJob & {
  leaseToken: string
  claimReason: "process" | "compensate"
}
type PublishedEdit = {
  chatId: number
  messageId: number
  senderId: number
  update: UpdateSeqAndDate
}

class BlockImageLeaseLostError extends Error {
  constructor() {
    super("block image job lease lost")
    this.name = "BlockImageLeaseLostError"
  }
}

class BlockImageCompensationError extends Error {
  constructor(error: unknown) {
    super("block image media compensation failed", { cause: error })
    this.name = "BlockImageCompensationError"
  }
}

class InvalidStoredBlockContentError extends Error {
  constructor(error: unknown) {
    super("stored block content failed validation during image publication", { cause: error })
    this.name = "InvalidStoredBlockContentError"
  }
}

type DeleteObject = (path: string) => Promise<void>

class BlockImageJobLease {
  private readonly controller = new AbortController()
  private heartbeat: ReturnType<typeof setInterval> | null = null
  private renewal: Promise<boolean> | null = null
  private leaseLost = false

  constructor(private readonly job: ClaimedJob) {}

  get signal(): AbortSignal {
    return this.controller.signal
  }

  get lost(): boolean {
    return this.leaseLost
  }

  start(): void {
    this.heartbeat = setInterval(() => {
      void this.ensureOwned().catch((error) => {
        log.warn("remote image lease heartbeat failed", {
          jobId: this.job.id.toString(),
          errorType: errorName(error),
        })
      })
    }, leaseHeartbeatMs)
  }

  async ensureOwned(): Promise<void> {
    if (this.leaseLost) throw new BlockImageLeaseLostError()
    let renewal = this.renewal
    if (!renewal) {
      renewal = renewJobLease(this.job).finally(() => {
        if (this.renewal === renewal) this.renewal = null
      })
      this.renewal = renewal
    }

    let owned: boolean
    try {
      owned = await renewal
    } catch (error) {
      this.markLost()
      throw error
    }
    if (!owned) {
      this.markLost()
      throw new BlockImageLeaseLostError()
    }
  }

  async stop(): Promise<void> {
    if (this.heartbeat !== null) {
      clearInterval(this.heartbeat)
      this.heartbeat = null
    }
    await this.renewal?.catch(() => undefined)
  }

  private markLost(): void {
    if (this.leaseLost) return
    this.leaseLost = true
    this.controller.abort(new BlockImageLeaseLostError())
  }
}

export async function runBlockContentImageWorkerOnce(limit = batchSize): Promise<number> {
  const claims = await claimJobs(limit)
  await Promise.all(claims.map(processJob))
  return claims.length
}

export type BlockContentImageWorkerOptions = {
  enabled?: boolean
  pollIntervalMs?: number
  runOnce?: () => Promise<number>
  setIntervalFn?: typeof setInterval
  clearIntervalFn?: typeof clearInterval
}

export class BlockContentImageWorker {
  private readonly enabled: boolean
  private readonly pollIntervalMs: number
  private readonly runOnce: () => Promise<number>
  private readonly setIntervalFn: typeof setInterval
  private readonly clearIntervalFn: typeof clearInterval
  private interval: ReturnType<typeof setInterval> | null = null
  private inFlight: Promise<void> | null = null
  private stopping = false

  constructor(options: BlockContentImageWorkerOptions = {}) {
    this.enabled = options.enabled ?? true
    this.pollIntervalMs = Math.max(100, options.pollIntervalMs ?? pollIntervalMs)
    this.runOnce = options.runOnce ?? (() => runBlockContentImageWorkerOnce())
    this.setIntervalFn = options.setIntervalFn ?? setInterval
    this.clearIntervalFn = options.clearIntervalFn ?? clearInterval
  }

  start(): boolean {
    if (!this.enabled || this.interval !== null) return false
    this.stopping = false
    this.interval = this.setIntervalFn(() => void this.pollOnce(), this.pollIntervalMs)
    void this.pollOnce()
    return true
  }

  async stop(): Promise<void> {
    this.stopping = true
    if (this.interval !== null) {
      this.clearIntervalFn(this.interval)
      this.interval = null
    }
    await this.inFlight
  }

  pollOnce(): Promise<void> {
    if (this.stopping) return Promise.resolve()
    if (this.inFlight) return this.inFlight
    let work: Promise<void>
    work = this.drainOnce().finally(() => {
      if (this.inFlight === work) this.inFlight = null
    })
    this.inFlight = work
    return work
  }

  private async drainOnce(): Promise<void> {
    try {
      await this.runOnce()
    } catch (error) {
      log.error("image worker tick failed", { errorType: errorName(error) })
    }
  }
}

let worker: BlockContentImageWorker | null = null

export function isBlockContentImageWorkerEnabled(
  value = process.env["BLOCK_CONTENT_IMAGE_WORKER_ENABLED"],
): boolean {
  const normalized = value?.trim().toLowerCase()
  return normalized !== "0" && normalized !== "false" && normalized !== "off"
}

export function startBlockContentImageWorker(): BlockContentImageWorker | null {
  if (isTest || !isBlockContentImageWorkerEnabled()) {
    if (!isTest) log.info("remote image worker disabled by configuration")
    return null
  }
  if (!worker) worker = new BlockContentImageWorker()
  worker.start()
  return worker
}

export async function stopBlockContentImageWorker(
  ownedWorker: BlockContentImageWorker | null = worker,
): Promise<void> {
  if (!ownedWorker) return
  await ownedWorker.stop()
  if (worker === ownedWorker) worker = null
}

export function resetBlockContentImageWorkerForTests(): void {
  worker = null
}

async function claimJobs(limit: number): Promise<ClaimedJob[]> {
  const now = new Date()
  return db.transaction(async (tx) => {
    const rows = await tx
      .select()
      .from(blockContentImageJobs)
      .where(and(
        lte(blockContentImageJobs.availableAt, now),
        or(
          eq(blockContentImageJobs.state, "pending"),
          and(eq(blockContentImageJobs.state, "processing"), lte(blockContentImageJobs.leaseUntil, now)),
          and(
            eq(blockContentImageJobs.state, "canceled"),
            isNotNull(blockContentImageJobs.stagedObjectPathEncrypted),
          ),
        ),
      ))
      .orderBy(asc(blockContentImageJobs.availableAt), asc(blockContentImageJobs.id))
      .limit(Math.max(1, Math.min(limit, 16)))
      .for("update", { skipLocked: true })

    const claimed: ClaimedJob[] = []
    for (const row of rows) {
      const leaseToken = randomUUID()
      const claimReason = row.state === "canceled" ? "compensate" : "process"
      await tx
        .update(blockContentImageJobs)
        .set({
          state: "processing",
          leaseToken,
          leaseUntil: new Date(now.getTime() + leaseMs),
          updatedAt: now,
        })
        .where(eq(blockContentImageJobs.id, row.id))
      claimed.push({
        ...row,
        state: "processing",
        leaseToken,
        leaseUntil: new Date(now.getTime() + leaseMs),
        claimReason,
      })
    }
    return claimed
  })
}

async function processJob(job: ClaimedJob): Promise<void> {
  const lease = new BlockImageJobLease(job)
  lease.start()
  try {
    if (job.claimReason === "compensate" || !await jobTargetIsCurrent(job)) {
      await compensateAndCancel(job)
      return
    }

    const source = decrypt({
      encrypted: job.sourceEncrypted,
      iv: job.sourceIv,
      authTag: job.sourceTag,
    })
    const owner = await ownerForContent(job.contentId)
    if (owner === undefined) {
      await compensateAndCancel(job)
      return
    }

    let photoId = job.photoId ?? undefined
    const stagedIdentity = stagedIdentityForJob(job)
    if (photoId === undefined && stagedIdentity) {
      photoId = await recoverStagedPhoto(job, stagedIdentity)
      if (photoId !== undefined && !await rememberUploadedPhoto(job, photoId)) {
        throw new BlockImageLeaseLostError()
      }
    }

    if (photoId === undefined) {
      const image = await downloadBlockImage(source, { signal: lease.signal })
      await lease.ensureOwned()
      const file = new File(
        [toArrayBufferBackedBytes(image.bytes)],
        fileNameForContentType(image.contentType),
        { type: image.contentType },
      )
      const uploaded = await uploadPhoto(file, { userId: owner }, {
        identity: stagedIdentity,
        onIdentityPrepared: async (identity) => {
          if (!await stageObjectPath(job, identity)) throw new BlockImageLeaseLostError()
        },
      })
      if (uploaded.photoId === undefined) throw new RemoteBlockImageError("uploaded_photo_missing", false)
      photoId = uploaded.photoId
      if (!await rememberUploadedPhoto(job, photoId)) throw new BlockImageLeaseLostError()
    } else {
      await lease.ensureOwned()
    }

    const photo = await FileModel.getPhotoById(BigInt(photoId))
    if (!photo) throw new RemoteBlockImageError("uploaded_photo_missing", false)

    await lease.ensureOwned()
    await lease.stop()
    const result = await publishJob(job, { oneofKind: "ready", ready: Encoders.photo({ photo }) })
    if (result.kind === "superseded") {
      await compensateAndCancel(job)
      return
    }
    await pushPublishedEdits(result.edits)
  } catch (error) {
    await lease.stop()
    if (lease.lost || error instanceof BlockImageLeaseLostError) {
      const lateCleanup = hasStagedObjectPath(job)
        ? await cleanupSettledUploadAfterLeaseLoss(job, deleteBlockImageObject).catch((cleanupError) => {
            log.warn("late remote image upload cleanup failed", {
              jobId: job.id.toString(),
              errorType: errorName(cleanupError),
            })
            return false
          })
        : false
      log.warn("remote image job stopped after losing its lease", {
        jobId: job.id.toString(),
        contentId: job.contentId.toString(),
        stagedMediaRetained: hasStagedObjectPath(job),
        lateCleanup,
      })
      return
    }
    await handleFailure(job, error)
  } finally {
    await lease.stop()
  }
}

async function renewJobLease(job: ClaimedJob): Promise<boolean> {
  const now = new Date()
  const [renewed] = await db
    .update(blockContentImageJobs)
    .set({ leaseUntil: new Date(now.getTime() + leaseMs), updatedAt: now })
    .where(and(
      eq(blockContentImageJobs.id, job.id),
      eq(blockContentImageJobs.state, "processing"),
      eq(blockContentImageJobs.leaseToken, job.leaseToken),
      gt(blockContentImageJobs.leaseUntil, now),
    ))
    .returning({ id: blockContentImageJobs.id })
  return renewed !== undefined
}

async function rememberUploadedPhoto(job: ClaimedJob, photoId: number): Promise<boolean> {
  const now = new Date()
  const [updated] = await db
    .update(blockContentImageJobs)
    .set({ photoId, updatedAt: now })
    .where(and(
      eq(blockContentImageJobs.id, job.id),
      eq(blockContentImageJobs.state, "processing"),
      eq(blockContentImageJobs.leaseToken, job.leaseToken),
      gt(blockContentImageJobs.leaseUntil, now),
    ))
    .returning({ id: blockContentImageJobs.id })
  return updated !== undefined
}

async function stageObjectPath(job: ClaimedJob, identity: FileObjectIdentity): Promise<boolean> {
  assertStagedIdentity(identity)
  const existing = stagedIdentityForJob(job)
  if (existing) {
    return existing.fileUniqueId === identity.fileUniqueId && existing.path === identity.path
  }

  const staged = encrypt(identity.path)
  const now = new Date()
  const [updated] = await db
    .update(blockContentImageJobs)
    .set({
      stagedObjectPathEncrypted: staged.encrypted,
      stagedObjectPathIv: staged.iv,
      stagedObjectPathTag: staged.authTag,
      updatedAt: now,
    })
    .where(and(
      eq(blockContentImageJobs.id, job.id),
      eq(blockContentImageJobs.state, "processing"),
      eq(blockContentImageJobs.leaseToken, job.leaseToken),
      gt(blockContentImageJobs.leaseUntil, now),
    ))
    .returning({ id: blockContentImageJobs.id })
  if (!updated) return false

  job.stagedObjectPathEncrypted = staged.encrypted
  job.stagedObjectPathIv = staged.iv
  job.stagedObjectPathTag = staged.authTag
  return true
}

async function recoverStagedPhoto(
  job: ClaimedJob,
  identity: FileObjectIdentity,
): Promise<number | undefined> {
  await assertJobOwned(job)
  const [file] = await db
    .select()
    .from(files)
    .where(eq(files.fileUniqueId, identity.fileUniqueId))
    .limit(1)
  if (!file) return undefined

  const filePath = decryptFilePath(file)
  if (filePath !== identity.path) {
    throw new RemoteBlockImageError("staged_photo_identity_conflict", true)
  }
  const sizes = await db
    .select({ photoId: photoSizes.photoId })
    .from(photoSizes)
    .where(and(eq(photoSizes.fileId, file.id), eq(photoSizes.size, "f")))
    .limit(2)
  const size = sizes[0]
  if (sizes.length !== 1 || !size || size.photoId === null) {
    throw new RemoteBlockImageError("staged_photo_graph_incomplete", false)
  }
  const [photo] = await db
    .select({ id: photos.id })
    .from(photos)
    .where(eq(photos.id, size.photoId))
    .limit(1)
  if (!photo) throw new RemoteBlockImageError("staged_photo_graph_incomplete", false)
  return photo.id
}

async function assertJobOwned(job: ClaimedJob): Promise<void> {
  const now = new Date()
  const [owned] = await db
    .select({ id: blockContentImageJobs.id })
    .from(blockContentImageJobs)
    .where(and(
      eq(blockContentImageJobs.id, job.id),
      eq(blockContentImageJobs.state, "processing"),
      eq(blockContentImageJobs.leaseToken, job.leaseToken),
      gt(blockContentImageJobs.leaseUntil, now),
    ))
    .limit(1)
  if (!owned) throw new BlockImageLeaseLostError()
}

async function jobTargetIsCurrent(job: ClaimedJob): Promise<boolean> {
  const [content] = await db
    .select()
    .from(blockContents)
    .where(eq(blockContents.id, job.contentId))
    .limit(1)
  if (!content || content.revision !== job.expectedRevision) return false

  const stored = decryptStoredBlockContent({
    encrypted: content.payloadEncrypted,
    iv: content.payloadIv,
    authTag: content.payloadTag,
  })
  return getBlockImageAtPath(stored.blockContent, job.blockPath)?.state.oneofKind === "pending"
}

function stagedIdentityForJob(job: DbBlockContentImageJob): FileObjectIdentity | undefined {
  if (!hasStagedObjectPath(job)) {
    if (job.stagedObjectPathEncrypted || job.stagedObjectPathIv || job.stagedObjectPathTag) {
      throw new Error("Incomplete staged block image object path")
    }
    return undefined
  }
  const path = decrypt({
    encrypted: job.stagedObjectPathEncrypted,
    iv: job.stagedObjectPathIv,
    authTag: job.stagedObjectPathTag,
  })
  const slash = path.indexOf("/")
  const identity = { fileUniqueId: slash > 0 ? path.slice(0, slash) : "", path }
  assertStagedIdentity(identity)
  return identity
}

function hasStagedObjectPath(job: DbBlockContentImageJob): job is DbBlockContentImageJob & {
  stagedObjectPathEncrypted: Buffer
  stagedObjectPathIv: Buffer
  stagedObjectPathTag: Buffer
} {
  return job.stagedObjectPathEncrypted !== null
    && job.stagedObjectPathIv !== null
    && job.stagedObjectPathTag !== null
}

function assertStagedIdentity(identity: FileObjectIdentity): void {
  if (!/^INP[A-Za-z0-9_-]{21}$/.test(identity.fileUniqueId)) {
    throw new Error("Invalid staged block image file identity")
  }
  if (!identity.path.startsWith(`${identity.fileUniqueId}/`)) {
    throw new Error("Staged block image path does not match its file identity")
  }
  const objectName = identity.path.slice(identity.fileUniqueId.length + 1)
  if (!/^[A-Za-z0-9_-]{32}(?:\.[a-z0-9]+)?$/.test(objectName)) {
    throw new Error("Invalid staged block image object path")
  }
}

function decryptFilePath(file: typeof files.$inferSelect): string | undefined {
  if (!file.pathEncrypted || !file.pathIv || !file.pathTag) return undefined
  return decrypt({ encrypted: file.pathEncrypted, iv: file.pathIv, authTag: file.pathTag })
}

async function ownerForContent(contentId: bigint): Promise<number | undefined> {
  const [message] = await db
    .select({ fromId: messages.fromId })
    .from(messages)
    .where(eq(messages.blockContentId, contentId))
    .orderBy(asc(messages.globalId))
    .limit(1)
  return message?.fromId
}

async function compensateAndCancel(job: ClaimedJob): Promise<void> {
  let compensated: boolean
  try {
    compensated = await compensateStagedMedia(job, "cancel", deleteBlockImageObject)
  } catch (error) {
    throw error instanceof BlockImageLeaseLostError
      ? error
      : new BlockImageCompensationError(error)
  }
  if (!compensated) throw new BlockImageLeaseLostError()

  await db.transaction(async (tx) => {
    await deleteUnreferencedBlockContents(tx, [job.contentId])
  })
}

export async function compensateClaimedBlockImageJobForTests(
  job: DbBlockContentImageJob & { leaseToken: string },
  deleteObject: DeleteObject,
): Promise<boolean> {
  return compensateStagedMedia(job, "cancel", deleteObject)
}

async function compensateStagedMedia(
  job: DbBlockContentImageJob & { leaseToken: string },
  completion: "cancel" | "retain",
  deleteObject: DeleteObject,
): Promise<boolean> {
  const compensated = await db.transaction(async (tx) => {
    const now = new Date()
    const [current] = await tx
      .select()
      .from(blockContentImageJobs)
      .where(and(
        eq(blockContentImageJobs.id, job.id),
        eq(blockContentImageJobs.state, "processing"),
        eq(blockContentImageJobs.leaseToken, job.leaseToken),
        gt(blockContentImageJobs.leaseUntil, now),
      ))
      .for("update")
      .limit(1)
    if (!current) return false

    const identity = stagedIdentityForJob(current)
    if (!identity) {
      await finishCompensation(tx, current.id, completion, now)
      return true
    }

    const graph = await loadStagedPhotoGraph(tx, identity, current.photoId)

    // Keep the row lock and lease fence across this one exact external delete.
    // A replacement worker cannot adopt the staged graph between object and DB
    // cleanup. If the DB commit fails, the retained staging row makes retrying
    // the idempotent object delete safe.
    await deleteObject(`${FILES_PATH_PREFIX}/${identity.path}`)

    await tx
      .update(blockContentImageJobs)
      .set({ photoId: null })
      .where(and(
        eq(blockContentImageJobs.id, current.id),
        eq(blockContentImageJobs.leaseToken, job.leaseToken),
      ))
    await deleteStagedPhotoGraph(tx, graph)
    await finishCompensation(tx, current.id, completion, now)
    return true
  })

  if (compensated) {
    job.photoId = null
    job.stagedObjectPathEncrypted = null
    job.stagedObjectPathIv = null
    job.stagedObjectPathTag = null
  }
  return compensated
}

async function cleanupSettledUploadAfterLeaseLoss(
  job: DbBlockContentImageJob,
  deleteObject: DeleteObject,
): Promise<boolean> {
  const identity = stagedIdentityForJob(job)
  if (!identity) return false

  const cleaned = await db.transaction(async (tx) => {
    const [current] = await tx
      .select()
      .from(blockContentImageJobs)
      .where(eq(blockContentImageJobs.id, job.id))
      .for("update")
      .limit(1)
    if (current && current.state !== "canceled") return false

    const durableIdentity = current ? stagedIdentityForJob(current) : undefined
    if (durableIdentity && (
      durableIdentity.fileUniqueId !== identity.fileUniqueId || durableIdentity.path !== identity.path
    )) return false

    const graph = await loadStagedPhotoGraph(tx, identity, current ? current.photoId : job.photoId)
    await deleteObject(`${FILES_PATH_PREFIX}/${identity.path}`)
    if (current) {
      await tx.update(blockContentImageJobs).set({
        stagedObjectPathEncrypted: null,
        stagedObjectPathIv: null,
        stagedObjectPathTag: null,
        photoId: null,
        updatedAt: new Date(),
      }).where(and(
        eq(blockContentImageJobs.id, current.id),
        eq(blockContentImageJobs.state, "canceled"),
      ))
    }
    await deleteStagedPhotoGraph(tx, graph)
    return true
  })

  if (cleaned) {
    job.photoId = null
    job.stagedObjectPathEncrypted = null
    job.stagedObjectPathIv = null
    job.stagedObjectPathTag = null
  }
  return cleaned
}

export async function cleanupSettledBlockImageUploadAfterLeaseLossForTests(
  job: DbBlockContentImageJob,
  deleteObject: DeleteObject,
): Promise<boolean> {
  return cleanupSettledUploadAfterLeaseLoss(job, deleteObject)
}

type StagedPhotoGraph = {
  file?: typeof files.$inferSelect
  photoIds: number[]
}

async function loadStagedPhotoGraph(
  tx: Transaction,
  identity: FileObjectIdentity,
  expectedPhotoId: number | null,
): Promise<StagedPhotoGraph> {
  const [file] = await tx
    .select()
    .from(files)
    .where(eq(files.fileUniqueId, identity.fileUniqueId))
    .for("update")
    .limit(1)
  if (file && decryptFilePath(file) !== identity.path) {
    throw new Error("Staged block image file path conflicts with its durable job identity")
  }

  const sizes = file
    ? await tx
        .select({ photoId: photoSizes.photoId })
        .from(photoSizes)
        .where(eq(photoSizes.fileId, file.id))
        .for("update")
    : []
  const photoIds = [...new Set([
    ...sizes.flatMap((size) => size.photoId === null ? [] : [size.photoId]),
    ...(expectedPhotoId === null ? [] : [expectedPhotoId]),
  ])]
  if (expectedPhotoId !== null && sizes.some((size) =>
    size.photoId !== null && size.photoId !== expectedPhotoId)) {
    throw new Error("Staged block image photo graph conflicts with its durable job identity")
  }
  return { file, photoIds }
}

async function deleteStagedPhotoGraph(tx: Transaction, graph: StagedPhotoGraph): Promise<void> {
  if (graph.file) await tx.delete(photoSizes).where(eq(photoSizes.fileId, graph.file.id))
  if (graph.photoIds.length > 0) await tx.delete(photos).where(inArray(photos.id, graph.photoIds))
  if (graph.file) await tx.delete(files).where(eq(files.id, graph.file.id))
}

async function finishCompensation(
  tx: Transaction,
  jobId: bigint,
  completion: "cancel" | "retain",
  now: Date,
): Promise<void> {
  await tx
    .update(blockContentImageJobs)
    .set({
      state: completion === "cancel" ? "canceled" : "processing",
      leaseToken: completion === "cancel" ? null : undefined,
      leaseUntil: completion === "cancel" ? null : undefined,
      stagedObjectPathEncrypted: null,
      stagedObjectPathIv: null,
      stagedObjectPathTag: null,
      photoId: null,
      updatedAt: now,
    })
    .where(eq(blockContentImageJobs.id, jobId))
}

async function deleteBlockImageObject(path: string): Promise<void> {
  await deleteFromBucket(path)
}

async function handleFailure(job: ClaimedJob, error: unknown): Promise<void> {
  const attempts = job.attempts + 1
  const terminal = error instanceof InvalidStoredBlockContentError ||
    (error instanceof RemoteBlockImageError ? error.permanent : attempts >= maxAttempts)
  const code = error instanceof RemoteBlockImageError ? error.code : errorName(error)
  const diagnostic = error instanceof RemoteBlockImageError ? error.diagnostic : undefined
  const metadata = {
    jobId: job.id.toString(),
    contentId: job.contentId.toString(),
    attempts,
    errorCode: code.slice(0, 64),
    blockCause: diagnostic?.cause,
    hostname: diagnostic?.hostname,
    transportErrorCode: diagnostic?.transportErrorCode,
    redirectHop: diagnostic?.redirectHop,
    answerCount: diagnostic?.answerCount,
    publicAnswerCount: diagnostic?.publicAnswerCount,
    filteredAnswerCount: diagnostic?.filteredAnswerCount,
  }

  if (error instanceof BlockImageCompensationError) {
    log.warn("remote image compensation will retry", metadata)
    await rescheduleJob(job, error, Math.min(attempts, maxAttempts))
    return
  }

  if (terminal || attempts >= maxAttempts) {
    log.warn("remote image reached a terminal failure", metadata)
    try {
      if (!await compensateStagedMedia(job, "retain", deleteBlockImageObject)) {
        throw new BlockImageLeaseLostError()
      }
      const result = await publishJob(job, { oneofKind: "unavailable", unavailable: {} }, code, attempts)
      if (result.kind === "superseded") {
        await compensateAndCancel(job)
      } else {
        await pushPublishedEdits(result.edits)
      }
    } catch (publishError) {
      log.warn("failed to publish unavailable image state", {
        jobId: job.id.toString(),
        errorType: errorName(publishError),
      })
      if (publishError instanceof InvalidStoredBlockContentError) {
        await quarantineInvalidStoredBlockContentJob(job, publishError, attempts)
      } else if (!(publishError instanceof BlockImageLeaseLostError)) {
        await rescheduleJob(job, publishError, Math.min(attempts, maxAttempts))
      }
    }
    return
  }

  await rescheduleJob(job, error, attempts)
}

async function quarantineInvalidStoredBlockContentJob(
  job: ClaimedJob,
  error: InvalidStoredBlockContentError,
  attempts: number,
): Promise<void> {
  const [failed] = await db
    .update(blockContentImageJobs)
    .set({
      state: "failed",
      attempts,
      leaseToken: null,
      leaseUntil: null,
      lastErrorCode: error.name,
      updatedAt: new Date(),
    })
    .where(and(
      eq(blockContentImageJobs.id, job.id),
      eq(blockContentImageJobs.state, "processing"),
      eq(blockContentImageJobs.leaseToken, job.leaseToken),
    ))
    .returning({ id: blockContentImageJobs.id })
  if (failed) {
    log.warn("quarantined invalid stored block content image job", {
      jobId: job.id.toString(),
      contentId: job.contentId.toString(),
    })
  }
}

async function rescheduleJob(job: ClaimedJob, error: unknown, attempts: number): Promise<void> {
  const code = error instanceof RemoteBlockImageError ? error.code : errorName(error)
  const now = new Date()
  const [rescheduled] = await db
    .update(blockContentImageJobs)
    .set({
      state: "pending",
      attempts,
      availableAt: new Date(Date.now() + retryDelayMs(attempts)),
      leaseToken: null,
      leaseUntil: null,
      lastErrorCode: code.slice(0, 64),
      updatedAt: now,
    })
    .where(and(
      eq(blockContentImageJobs.id, job.id),
      eq(blockContentImageJobs.state, "processing"),
      eq(blockContentImageJobs.leaseToken, job.leaseToken),
      gt(blockContentImageJobs.leaseUntil, now),
    ))
    .returning({ id: blockContentImageJobs.id })

  if (rescheduled) log.warn("remote image retry scheduled", {
    jobId: job.id.toString(),
    contentId: job.contentId.toString(),
    attempts,
    errorCode: code.slice(0, 64),
  })
  else log.warn("remote image retry skipped after lease loss", {
    jobId: job.id.toString(),
    contentId: job.contentId.toString(),
    attempts,
    errorCode: code.slice(0, 64),
  })
}

async function publishJob(
  job: ClaimedJob,
  state: BlockImage["state"],
  failureCode?: string,
  attempts = job.attempts,
): Promise<{ kind: "published"; edits: PublishedEdit[] } | { kind: "superseded" }> {
  const references = await db
    .select({ chatId: messages.chatId })
    .from(messages)
    .where(eq(messages.blockContentId, job.contentId))
  const chatIds = [...new Set(references.map((reference) => reference.chatId))].sort((a, b) => a - b)
  if (chatIds.length === 0) {
    return { kind: "superseded" }
  }

  return db.transaction(async (tx) => {
    const leaseCheckAt = new Date()
    const lockedChats = await tx
      .select()
      .from(chats)
      .where(inArray(chats.id, chatIds))
      .orderBy(asc(chats.id))
      .for("update")
    const lockedMessages = await tx
      .select()
      .from(messages)
      .where(eq(messages.blockContentId, job.contentId))
      .orderBy(asc(messages.chatId), asc(messages.messageId))
      .for("update")
    const [content] = await tx
      .select()
      .from(blockContents)
      .where(eq(blockContents.id, job.contentId))
      .for("update")
      .limit(1)
    const [currentJob] = await tx
      .select()
      .from(blockContentImageJobs)
      .where(and(
        eq(blockContentImageJobs.id, job.id),
        eq(blockContentImageJobs.state, "processing"),
        eq(blockContentImageJobs.leaseToken, job.leaseToken),
        gt(blockContentImageJobs.leaseUntil, leaseCheckAt),
      ))
      .for("update")
      .limit(1)

    if (!content || !currentJob || currentJob.state !== "processing" ||
        content.revision !== currentJob.expectedRevision || lockedMessages.length === 0) {
      return { kind: "superseded" } as const
    }

    let stored: ReturnType<typeof decryptStoredBlockContent>
    try {
      stored = decryptStoredBlockContent({
        encrypted: content.payloadEncrypted,
        iv: content.payloadIv,
        authTag: content.payloadTag,
      })
    } catch (error) {
      if (error instanceof StoredBlockContentPayloadError) {
        throw new InvalidStoredBlockContentError(error)
      }
      throw error
    }
    const existingImage = getBlockImageAtPath(stored.blockContent, currentJob.blockPath)
    if (!existingImage || existingImage.state.oneofKind !== "pending") {
      return { kind: "superseded" } as const
    }

    const replacement: BlockImage = {
      alt: existingImage.alt,
      state: state.oneofKind === "unavailable"
        ? {
            oneofKind: "unavailable",
            unavailable: {
              dimensions: existingImage.state.pending.dimensions,
            },
          }
        : state,
    }
    if (!replaceBlockImageAtPath(stored.blockContent, currentJob.blockPath, replacement)) {
      throw new Error("Block image path changed while publishing")
    }
    try {
      validateBlockContent(stored.text, stored.blockContent, "persisted")
      assertStoredBlockContentPayloadFits(stored)
    } catch (error) {
      throw new InvalidStoredBlockContentError(error)
    }
    const encrypted = encryptStoredBlockContent(stored)
    const nextRevision = content.revision + 1

    const [updatedContent] = await tx
      .update(blockContents)
      .set({
        payloadEncrypted: encrypted.encrypted,
        payloadIv: encrypted.iv,
        payloadTag: encrypted.authTag,
        revision: nextRevision,
        updatedAt: new Date(),
      })
      .where(and(eq(blockContents.id, content.id), eq(blockContents.revision, content.revision)))
      .returning({ id: blockContents.id })
    if (!updatedContent) return { kind: "superseded" } as const

    await tx
      .update(blockContentImageJobs)
      .set({ expectedRevision: nextRevision, updatedAt: new Date() })
      .where(and(
        eq(blockContentImageJobs.contentId, content.id),
        eq(blockContentImageJobs.expectedRevision, content.revision),
        not(eq(blockContentImageJobs.state, "canceled")),
      ))
    const [finishedJob] = await tx
      .update(blockContentImageJobs)
      .set({
        state: state.oneofKind === "ready" ? "ready" : "failed",
        attempts,
        leaseToken: null,
        leaseUntil: null,
        photoId: state.oneofKind === "ready" ? Number(state.ready.id) : null,
        stagedObjectPathEncrypted: null,
        stagedObjectPathIv: null,
        stagedObjectPathTag: null,
        lastErrorCode: failureCode?.slice(0, 64) ?? null,
        updatedAt: new Date(),
      })
      .where(and(eq(blockContentImageJobs.id, currentJob.id), eq(blockContentImageJobs.leaseToken, job.leaseToken)))
      .returning({ id: blockContentImageJobs.id })
    if (!finishedJob) throw new BlockImageLeaseLostError()

    const editedMessages = lockedMessages.length > 0
      ? await tx
          .update(messages)
          .set({ rev: sql`${messages.rev} + 1` })
          .where(inArray(messages.globalId, lockedMessages.map((message) => message.globalId)))
          .returning({
            chatId: messages.chatId,
            messageId: messages.messageId,
            senderId: messages.fromId,
            globalId: messages.globalId,
            rev: messages.rev,
          })
      : []

    // Image enrichment changes presentation, not text or entities. Advance
    // existing graph fences atomically with the message revision so links do
    // not disappear until an asynchronous materializer catches up.
    for (const message of editedMessages) {
      await tx
        .update(threadGraphLinks)
        .set({ fromMessageRevision: message.rev, updatedAt: new Date() })
        .where(and(
          eq(threadGraphLinks.kind, "thread_link"),
          eq(threadGraphLinks.fromMessageGlobalId, message.globalId),
          eq(threadGraphLinks.fromMessageRevision, message.rev - 1),
          isNull(threadGraphLinks.deletedAt),
        ))
    }

    const chatsById = new Map(lockedChats.map((chat) => [chat.id, chat]))
    const nextSeq = new Map(lockedChats.map((chat) => [chat.id, chat.updateSeq ?? 0]))
    const lastUpdate = new Map<number, Date>()
    const published: PublishedEdit[] = []
    for (const message of editedMessages) {
      const chat = chatsById.get(message.chatId)
      if (!chat) continue
      const entity = { id: chat.id, updateSeq: nextSeq.get(chat.id) ?? 0 }
      const update = await UpdatesModel.insertUpdate(tx, {
        update: {
          oneofKind: "editMessage",
          editMessage: { chatId: BigInt(message.chatId), msgId: BigInt(message.messageId) },
        },
        bucket: UpdateBucket.Chat,
        entity,
      })
      nextSeq.set(chat.id, update.seq)
      lastUpdate.set(chat.id, update.date)
      published.push({ ...message, update })
    }
    for (const chat of lockedChats) {
      const seq = nextSeq.get(chat.id)
      const date = lastUpdate.get(chat.id)
      if (seq !== undefined && date) {
        await tx.update(chats).set({ updateSeq: seq, lastUpdateDate: date }).where(eq(chats.id, chat.id))
      }
    }
    return { kind: "published", edits: published } as const
  })
}

export async function publishClaimedBlockImageJobForTests(
  job: DbBlockContentImageJob & { leaseToken: string },
  state: BlockImage["state"],
): Promise<"published" | "superseded"> {
  return (await publishJob({ ...job, claimReason: "process" }, state)).kind
}

async function pushPublishedEdits(edits: PublishedEdit[]): Promise<void> {
  for (const edit of edits) {
    try {
      const [chat, message] = await Promise.all([
        db._query.chats.findFirst({ where: eq(chats.id, edit.chatId) }),
        MessageModel.getMessage(edit.messageId, edit.chatId),
      ])
      if (!chat || !message) continue
      if (message.entities?.entities.some((entity) => entity.type === MessageEntity_Type.THREAD)) {
        // The initial graph task can race the image revision before a link row
        // exists. Requeue the current snapshot; graph deduplication owns reuse.
        queueMessageThreadLinkMaterialization({
          sourceChat: chat,
          sourceChatId: chat.id,
          sourceMessageGlobalId: message.globalId,
          sourceMessageId: message.messageId,
          sourceMessageFromId: message.fromId,
          sourceMessageRevision: message.rev,
          entities: message.entities,
        })
      }
      const senderPeer = encodePeerFromChat(chat, { currentUserId: edit.senderId })
      const updateGroup = await getUpdateGroupFromInputPeer(senderPeer, { currentUserId: edit.senderId })
      for (const userId of updateGroup.userIds) {
        const threadProjection = (
          await getMessageThreadProjectionsMap({
            parentChatId: chat.id,
            parentMessageIds: [message.messageId],
            userId,
          })
        ).get(message.messageId)
        const update: Update = {
          seq: edit.update.seq,
          date: encodeDateStrict(edit.update.date),
          update: {
            oneofKind: "editMessage",
            editMessage: {
              message: Encoders.fullMessage({
                message,
                encodingForUserId: userId,
                encodingForPeer: { inputPeer: encodePeerFromChat(chat, { currentUserId: userId }) },
                replies: threadProjection?.replies,
                subthread: threadProjection?.subthread,
              }),
            },
          },
        }
        RealtimeUpdates.pushToUser(userId, [update])
      }
    } catch (error) {
      log.warn("durable image edit could not be pushed live", {
        chatId: edit.chatId,
        messageId: edit.messageId,
        errorType: errorName(error),
      })
    }
  }
}

function retryDelayMs(attempts: number): number {
  return Math.min(5 * 60_000, 2_000 * 2 ** Math.min(Math.max(attempts - 1, 0), 8))
}

function fileNameForContentType(contentType: string): string {
  switch (contentType) {
    case "image/png": return "remote-image.png"
    case "image/gif": return "remote-image.gif"
    case "image/webp": return "remote-image.webp"
    default: return "remote-image.jpg"
  }
}

function errorName(error: unknown): string {
  return error instanceof Error ? error.name : "UnknownError"
}
