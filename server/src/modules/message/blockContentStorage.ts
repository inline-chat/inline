import type { BlockContent, BlockImage, MessageEntities } from "@inline-chat/protocol/core"
import { blockContentImageJobs, blockContents, messages } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import { encrypt, type EncryptedData } from "@in/server/modules/encryption/encryption"
import { createHash } from "node:crypto"
import { and, eq, inArray, isNotNull, not, notInArray, sql } from "drizzle-orm"
import {
  getBlockImageAtPath,
  type BlockImageSource,
  type ParsedBlockContent,
} from "./blockContent"
import { decryptStoredBlockContent, encryptStoredBlockContent } from "./blockContentPayload"

export type PreparedBlockContent = {
  text: string
  entities?: MessageEntities
  blockContent: BlockContent
  payload: EncryptedData
  imageJobs: PreparedBlockImageJob[]
}

type PreparedBlockImageJob = {
  path: number[]
  sourceHash: Buffer
  source: EncryptedData
}

export function prepareBlockContent(input: {
  text: string
  entities?: MessageEntities
  parsed: ParsedBlockContent | undefined
}): PreparedBlockContent | undefined {
  if (!input.parsed) return undefined

  return {
    text: input.text,
    entities: input.entities,
    blockContent: input.parsed.blockContent,
    payload: encryptStoredBlockContent({
      text: input.text,
      entities: input.entities,
      blockContent: input.parsed.blockContent,
    }),
    imageJobs: input.parsed.imageSources.map(prepareImageJob),
  }
}

export async function insertPreparedBlockContent(
  tx: Transaction,
  prepared: PreparedBlockContent,
  revision: number,
): Promise<bigint> {
  const [content] = await tx
    .insert(blockContents)
    .values({
      payloadEncrypted: prepared.payload.encrypted,
      payloadIv: prepared.payload.iv,
      payloadTag: prepared.payload.authTag,
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

  const reusableJobs = new Map(
    currentJobs
      .filter((job) => job.state !== "canceled" && job.expectedRevision === input.currentRevision)
      .map((job) => [imageJobKey(job.blockPath, job.sourceHash), job]),
  )
  const newJobs: PreparedBlockImageJob[] = []
  const reusedJobIds: bigint[] = []

  for (const job of input.prepared.imageJobs) {
    const reusable = reusableJobs.get(imageJobKey(job.path, job.sourceHash))
    const priorImage = reusable ? getBlockImageAtPath(oldSnapshot, reusable.blockPath) : undefined
    const nextImage = getBlockImageAtPath(input.prepared.blockContent, job.path)
    if (reusable && priorImage && nextImage && reuseBlockImageState(nextImage, priorImage)) {
      reusedJobIds.push(reusable.id)
    } else {
      newJobs.push(job)
    }
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
        reusedJobIds.length > 0 ? notInArray(blockContentImageJobs.id, reusedJobIds) : undefined,
        not(activeStagedUpload()),
      ),
    )
  if (reusedJobIds.length > 0) {
    await input.tx
      .update(blockContentImageJobs)
      .set({ expectedRevision: nextRevision, updatedAt: new Date() })
      .where(inArray(blockContentImageJobs.id, reusedJobIds))
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
      sourceEncrypted: job.source.encrypted,
      sourceIv: job.source.iv,
      sourceTag: job.source.authTag,
    })),
  )
}

function prepareImageJob(source: BlockImageSource): PreparedBlockImageJob {
  return {
    path: source.path,
    sourceHash: createHash("sha256").update(source.url).digest(),
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
  return `${path.join(".")}:${Buffer.from(sourceHash).toString("hex")}`
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
