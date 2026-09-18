import type { BlockContent, BlockImage, MessageEntities } from "@inline-chat/protocol/core"
import { blockContentImageJobs, blockContents, messages } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { decrypt, encrypt, type EncryptedData } from "@in/server/modules/encryption/encryption"
import { createHash } from "node:crypto"
import { contentEncryptionWritesEnabled, contentLookup } from "../encryption/contentEncryption"
import { and, eq, inArray, isNotNull, not, notInArray, sql } from "drizzle-orm"
import {
  getBlockImageAtPath,
  type BlockImageSource,
  type ParsedBlockContent,
} from "./blockContent"
import {
  assertStoredBlockContentPayloadFits,
  decryptStoredBlockContent,
  encryptStoredBlockContent,
} from "./blockContentPayload"

export type PreparedBlockContent = {
  text: string
  entities?: MessageEntities
  blockContent: BlockContent
  imageJobs: PreparedBlockImageJob[]
}

type PreparedBlockImageJob = {
  path: number[]
  sourceHash: Buffer
  hashVersion: number
  source: EncryptedData
}

export function prepareBlockContent(input: {
  text: string
  entities?: MessageEntities
  parsed: ParsedBlockContent | undefined
}): PreparedBlockContent | undefined {
  if (!input.parsed) return undefined

  const prepared: PreparedBlockContent = {
    text: input.text,
    entities: input.entities,
    blockContent: input.parsed.blockContent,
    imageJobs: input.parsed.imageSources.map(prepareImageJob),
  }
  // Keep canonical-size failures inside the caller's plain-text fallback
  // boundary without paying the encryption cost before the transaction.
  assertStoredBlockContentPayloadFits(prepared)
  return prepared
}

export async function insertPreparedBlockContent(
  tx: Transaction,
  prepared: PreparedBlockContent,
  revision: number,
): Promise<bigint> {
  const payload = encryptStoredBlockContent({
    text: prepared.text,
    entities: prepared.entities,
    blockContent: prepared.blockContent,
  })
  const [content] = await tx
    .insert(blockContents)
    .values({
      payloadEncrypted: payload.encrypted,
      payloadIv: payload.iv,
      payloadTag: payload.authTag,
      revision,
    })
    .returning({ id: blockContents.id })

  if (!content) throw new Error("Failed to insert block content")
  await insertImageJobs(tx, content.id, revision, prepared.imageJobs)
  return content.id
}

export async function replacePreparedBlockContent(input: {
  tx: Transaction
  contentId: bigint
  currentRevision: number
  prepared: PreparedBlockContent
}): Promise<number> {
  const nextRevision = input.currentRevision + 1
  const [current] = await input.tx
    .select()
    .from(blockContents)
    .where(andContentRevision(input.contentId, input.currentRevision))
    .limit(1)
  if (!current) throw new Error("Block content revision changed concurrently")

  const oldSnapshot = decryptStoredBlockContent({
    encrypted: current.payloadEncrypted,
    iv: current.payloadIv,
    authTag: current.payloadTag,
  }).blockContent
  const currentJobs = await input.tx
    .select()
    .from(blockContentImageJobs)
    .where(eqContent(input.contentId))

  const activeJobs = currentJobs
    .filter((job) => job.state !== "canceled" && job.expectedRevision === input.currentRevision)
    .map((job) => ({ ...job, sourceHash: hashBlockImageSource(decrypt({
      encrypted: job.sourceEncrypted, iv: job.sourceIv, authTag: job.sourceTag,
    })) }))
  const exactJobs = new Map<string, (typeof activeJobs)[number][]>()
  for (const job of activeJobs) {
    const key = imageJobKey(job.blockPath, job.sourceHash)
    const values = exactJobs.get(key) ?? []
    values.push(job)
    exactJobs.set(key, values)
  }
  const newJobs: PreparedBlockImageJob[] = []
  const reusedJobs: { id: bigint; oldPath: number[]; nextPath: number[] }[] = []
  const reusedJobIds = new Set<bigint>()
  const matchedPrepared = new Set<PreparedBlockImageJob>()

  const tryReuse = (job: PreparedBlockImageJob, reusable: (typeof activeJobs)[number]): boolean => {
    if (reusedJobIds.has(reusable.id)) return false
    const priorImage = getBlockImageAtPath(oldSnapshot, reusable.blockPath)
    const nextImage = getBlockImageAtPath(input.prepared.blockContent, job.path)
    if (!priorImage || !nextImage || !reuseBlockImageState(nextImage, priorImage)) return false
    reusedJobIds.add(reusable.id)
    reusedJobs.push({ id: reusable.id, oldPath: reusable.blockPath, nextPath: job.path })
    matchedPrepared.add(job)
    return true
  }

  // Preserve exact occurrences first, including duplicate URLs in an album.
  for (const job of input.prepared.imageJobs) {
    for (const reusable of exactJobs.get(imageJobKey(job.path, job.sourceHash)) ?? []) {
      if (tryReuse(job, reusable)) break
    }
  }

  // A streamed prefix insertion changes every later block path. Reconcile a
  // moved occurrence only when its source is unique on both sides; duplicate
  // sources are intentionally ambiguous and receive fresh jobs.
  const remainingPreparedByHash = new Map<string, PreparedBlockImageJob[]>()
  for (const job of input.prepared.imageJobs) {
    if (matchedPrepared.has(job)) continue
    const key = sourceHashKey(job.sourceHash)
    const values = remainingPreparedByHash.get(key) ?? []
    values.push(job)
    remainingPreparedByHash.set(key, values)
  }
  const remainingCurrentByHash = new Map<string, (typeof activeJobs)[number][]>()
  for (const job of activeJobs) {
    if (reusedJobIds.has(job.id)) continue
    const key = sourceHashKey(job.sourceHash)
    const values = remainingCurrentByHash.get(key) ?? []
    values.push(job)
    remainingCurrentByHash.set(key, values)
  }
  for (const [hash, preparedJobs] of remainingPreparedByHash) {
    const reusable = remainingCurrentByHash.get(hash)
    if (preparedJobs.length === 1 && reusable?.length === 1) {
      tryReuse(preparedJobs[0]!, reusable[0]!)
    }
  }
  for (const job of input.prepared.imageJobs) {
    if (!matchedPrepared.has(job)) newJobs.push(job)
  }

  const payload = encryptStoredBlockContent({
    text: input.prepared.text,
    entities: input.prepared.entities,
    blockContent: input.prepared.blockContent,
  })
  const [updated] = await input.tx
    .update(blockContents)
    .set({
      payloadEncrypted: payload.encrypted,
      payloadIv: payload.iv,
      payloadTag: payload.authTag,
      revision: nextRevision,
      updatedAt: new Date(),
    })
    .where(andContentRevision(input.contentId, input.currentRevision))
    .returning({ id: blockContents.id })

  if (!updated) throw new Error("Block content revision changed concurrently")

  await input.tx
    .update(blockContentImageJobs)
    .set({
      state: "canceled",
      availableAt: new Date(),
      leaseToken: null,
      leaseUntil: null,
      updatedAt: new Date(),
    })
    .where(
      and(
        eqContent(input.contentId),
        reusedJobIds.size > 0 ? notInArray(blockContentImageJobs.id, [...reusedJobIds]) : undefined,
        not(activeStagedUpload()),
      ),
    )
  if (reusedJobIds.size > 0) {
    await input.tx
      .update(blockContentImageJobs)
      .set({ expectedRevision: nextRevision, updatedAt: new Date() })
      .where(inArray(blockContentImageJobs.id, [...reusedJobIds]))
    for (const job of reusedJobs) {
      if (sameBlockPath(job.oldPath, job.nextPath)) continue
      await input.tx
        .update(blockContentImageJobs)
        .set({ blockPath: job.nextPath, updatedAt: new Date() })
        .where(eq(blockContentImageJobs.id, job.id))
    }
  }
  await insertImageJobs(input.tx, input.contentId, nextRevision, newJobs)
  return nextRevision
}

export async function deleteUnreferencedBlockContents(
  tx: Transaction,
  candidateIds?: bigint[],
): Promise<void> {
  const uniqueIds = candidateIds ? [...new Set(candidateIds)] : undefined
  if (uniqueIds?.length === 0) return

  const unreferencedJob = sql`not exists (
    select 1 from ${messages}
    where ${messages.blockContentId} = ${blockContentImageJobs.contentId}
  )`
  await tx
    .update(blockContentImageJobs)
    .set({
      state: "canceled",
      availableAt: new Date(),
      leaseToken: null,
      leaseUntil: null,
      updatedAt: new Date(),
    })
    .where(and(
      uniqueIds ? inArray(blockContentImageJobs.contentId, uniqueIds) : undefined,
      unreferencedJob,
      not(activeStagedUpload()),
    ))

  await tx
    .delete(blockContents)
    .where(and(
      uniqueIds ? inArray(blockContents.id, uniqueIds) : undefined,
      sql`not exists (
        select 1 from ${messages}
        where ${messages.blockContentId} = ${blockContents.id}
      )`,
      sql`not exists (
        select 1 from ${blockContentImageJobs}
        where ${blockContentImageJobs.contentId} = ${blockContents.id}
          and ${blockContentImageJobs.stagedObjectPathEncrypted} is not null
      )`,
    ))
}

async function insertImageJobs(
  tx: Transaction,
  contentId: bigint,
  expectedRevision: number,
  jobs: PreparedBlockImageJob[],
): Promise<void> {
  if (jobs.length === 0) return
  await tx.insert(blockContentImageJobs).values(
    jobs.map((job) => ({
      contentId,
      expectedRevision,
      blockPath: job.path,
      sourceHash: job.sourceHash,
      hashVersion: job.hashVersion,
      sourceEncrypted: job.source.encrypted,
      sourceIv: job.source.iv,
      sourceTag: job.source.authTag,
    })),
  )
}

const hashBlockImageSource = (url: string): Buffer => contentEncryptionWritesEnabled()
  ? contentLookup("block-image-url", [], url) : createHash("sha256").update(url).digest()

function prepareImageJob(source: BlockImageSource): PreparedBlockImageJob {
  return {
    path: source.path,
    sourceHash: hashBlockImageSource(source.url),
    hashVersion: contentEncryptionWritesEnabled() ? 1 : 0,
    source: encrypt(source.url),
  }
}

// Kept as tiny local helpers so the write functions cannot accidentally omit
// either side of their compare-and-set predicates.
const andContentRevision = (contentId: bigint, revision: number) =>
  and(eq(blockContents.id, contentId), eq(blockContents.revision, revision))
const eqContent = (contentId: bigint) => eq(blockContentImageJobs.contentId, contentId)

const activeStagedUpload = () => and(
  eq(blockContentImageJobs.state, "processing"),
  isNotNull(blockContentImageJobs.leaseToken),
  isNotNull(blockContentImageJobs.leaseUntil),
  isNotNull(blockContentImageJobs.stagedObjectPathEncrypted),
  isNotNull(blockContentImageJobs.stagedObjectPathIv),
  isNotNull(blockContentImageJobs.stagedObjectPathTag),
)!

function imageJobKey(path: number[], sourceHash: Uint8Array): string {
  return `${path.join(".")}:${sourceHashKey(sourceHash)}`
}

function sourceHashKey(sourceHash: Uint8Array): string {
  return Buffer.from(sourceHash).toString("hex")
}

function sameBlockPath(left: number[], right: number[]): boolean {
  return left.length === right.length && left.every((value, index) => value === right[index])
}

/**
 * Reuse only server-owned media progress. The freshly parsed image remains the
 * authority for its alt-text range and authored dimensions after an edit.
 */
function reuseBlockImageState(nextImage: BlockImage, priorImage: BlockImage): boolean {
  switch (priorImage.state.oneofKind) {
    case "ready":
      nextImage.state = priorImage.state
      return true
    case "unavailable": {
      const authoredDimensions = nextImage.state.oneofKind === "pending"
        ? nextImage.state.pending.dimensions
        : undefined
      nextImage.state = {
        oneofKind: "unavailable",
        unavailable: {
          dimensions: authoredDimensions ?? priorImage.state.unavailable.dimensions,
        },
      }
      return true
    }
    case "pending": {
      if (nextImage.state.oneofKind !== "pending") return false
      nextImage.state = {
        oneofKind: "pending",
        pending: {
          dimensions: nextImage.state.pending.dimensions ?? priorImage.state.pending.dimensions,
          strippedThumbnail: priorImage.state.pending.strippedThumbnail
            ?? nextImage.state.pending.strippedThumbnail,
        },
      }
      return true
    }
    case undefined:
      return false
  }
}
