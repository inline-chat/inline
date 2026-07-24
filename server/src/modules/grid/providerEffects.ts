import type { GridConnection } from "@inline-chat/protocol/core"
import { db } from "@in/server/db"
import { gridProviderEffects, type DbGridProviderEffect } from "@in/server/db/schema"
import type { Transaction } from "@in/server/db/types"
import {
  closeGridConnection,
  getLiveKitGridConfig,
  GRID_PROVIDER_HTTP_POLICY,
  revokeGridParticipantAccess,
} from "@in/server/modules/grid/livekit"
import { Log } from "@in/server/utils/log"
import { and, asc, eq, inArray, isNull, lte, or } from "drizzle-orm"
import { ServerError } from "livekit-server-sdk"
import { randomUUID } from "node:crypto"

const CONNECTION_CLEANUP_GRACE_MS = 30_000
const DEFAULT_POLL_INTERVAL_MS = 2_000
const DEFAULT_CLAIM_LEASE_MS = 30_000
const DEFAULT_PROVIDER_TIMEOUT_MS = GRID_PROVIDER_HTTP_POLICY.workerTimeoutSeconds * 1_000
const DEFAULT_BATCH_SIZE = 8
const MAX_RETRY_DELAY_MS = 5 * 60_000
const log = new Log("grid.providerEffects")

export type GridProviderEffectKind = "close_connection" | "revoke_participant"

type ClaimedGridProviderEffect = DbGridProviderEffect & {
  claimToken: string
}

type SetIntervalFn = (handler: () => void, timeout: number) => ReturnType<typeof setInterval>
type ClearIntervalFn = (id: ReturnType<typeof setInterval>) => void

export type GridProviderEffectWorkerOptions = {
  pollIntervalMs?: number
  claimLeaseMs?: number
  providerTimeoutMs?: number
  batchSize?: number
  now?: () => number
  setIntervalFn?: SetIntervalFn
  clearIntervalFn?: ClearIntervalFn
  claim?: (input: { now: Date; claimLeaseMs: number; batchSize: number }) => Promise<ClaimedGridProviderEffect[]>
  execute?: (effect: ClaimedGridProviderEffect) => Promise<void>
  complete?: (effect: ClaimedGridProviderEffect) => Promise<void>
  retry?: (effect: ClaimedGridProviderEffect, error: unknown, now: Date) => Promise<void>
}

/** Must be called inside the mutation transaction that ended the generation. */
export async function enqueueGridConnectionCleanup(
  tx: Transaction,
  connection: Pick<GridConnection, "roomId" | "generation">,
  now = Date.now(),
): Promise<void> {
  await tx
    .insert(gridProviderEffects)
    .values({
      kind: "close_connection",
      deduplicationKey: providerEffectKey("close_connection", connection),
      roomId: Number(connection.roomId),
      connectionGeneration: connection.generation,
      availableAt: new Date(now + CONNECTION_CLEANUP_GRACE_MS),
    })
    .onConflictDoNothing({ target: gridProviderEffects.deduplicationKey })
}

/** Must be called inside the transaction that removed this participant. */
export async function enqueueGridParticipantRevocation(
  tx: Transaction,
  connection: Pick<GridConnection, "roomId" | "generation">,
  userId: number,
  participantIdentity: string,
  now = Date.now(),
): Promise<void> {
  await tx
    .insert(gridProviderEffects)
    .values({
      kind: "revoke_participant",
      deduplicationKey: providerEffectKey("revoke_participant", connection, participantIdentity),
      roomId: Number(connection.roomId),
      connectionGeneration: connection.generation,
      userId,
      participantIdentity,
      availableAt: new Date(now),
    })
    .onConflictDoNothing({ target: gridProviderEffects.deduplicationKey })
}

export class GridProviderEffectWorker {
  private readonly runtime: Required<
    Pick<
      GridProviderEffectWorkerOptions,
      "pollIntervalMs" | "claimLeaseMs" | "providerTimeoutMs" | "batchSize" | "now" | "setIntervalFn" | "clearIntervalFn"
    >
  > & Pick<GridProviderEffectWorkerOptions, "claim" | "execute" | "complete" | "retry">
  private intervalId: ReturnType<typeof setInterval> | null = null
  private inFlight: Promise<void> | null = null
  private claimFailureCount = 0

  constructor(options: GridProviderEffectWorkerOptions = {}) {
    this.runtime = {
      pollIntervalMs: positiveInt(options.pollIntervalMs, DEFAULT_POLL_INTERVAL_MS),
      claimLeaseMs: positiveInt(options.claimLeaseMs, DEFAULT_CLAIM_LEASE_MS),
      providerTimeoutMs: positiveInt(options.providerTimeoutMs, DEFAULT_PROVIDER_TIMEOUT_MS),
      batchSize: positiveInt(options.batchSize, DEFAULT_BATCH_SIZE),
      now: options.now ?? Date.now,
      setIntervalFn: options.setIntervalFn ?? setInterval,
      clearIntervalFn: options.clearIntervalFn ?? clearInterval,
      claim: options.claim,
      execute: options.execute,
      complete: options.complete,
      retry: options.retry,
    }
  }

  start(): void {
    if (this.intervalId !== null) return
    this.intervalId = this.runtime.setIntervalFn(() => void this.pollOnce(), this.runtime.pollIntervalMs)
    void this.pollOnce()
  }

  async stop(): Promise<void> {
    if (this.intervalId !== null) {
      this.runtime.clearIntervalFn(this.intervalId)
      this.intervalId = null
    }
    await this.inFlight
  }

  pollOnce(): Promise<void> {
    if (this.inFlight) return this.inFlight
    let work: Promise<void>
    work = this.drainOnce().finally(() => {
      if (this.inFlight === work) this.inFlight = null
    })
    this.inFlight = work
    return work
  }

  private async drainOnce(): Promise<void> {
    const now = new Date(this.runtime.now())
    let effects: ClaimedGridProviderEffect[]
    try {
      effects = await (this.runtime.claim ?? claimGridProviderEffects)({
        now,
        claimLeaseMs: this.runtime.claimLeaseMs,
        batchSize: this.runtime.batchSize,
      })
    } catch (error) {
      this.claimFailureCount += 1
      if (this.claimFailureCount === 1 || this.claimFailureCount === 10 || this.claimFailureCount % 100 === 0) {
        Log.shared.warn("Failed to claim durable Grid provider effects", {
          consecutiveFailures: this.claimFailureCount,
          error,
        })
      }
      return
    }
    if (this.claimFailureCount > 0) {
      log.info("GRID_TRACE phase=provider_effect_claim_recovered", {
        previousFailures: this.claimFailureCount,
      })
      this.claimFailureCount = 0
    }
    await Promise.all(
      effects.map(async (effect) => {
        try {
          await this.process(effect)
        } catch (error) {
          // A database outage can prevent both completion and retry writes. The
          // claim lease then expires, allowing this or another process to retry.
          Log.shared.warn("Failed to persist Grid provider effect result", {
            effectId: effect.id,
            kind: effect.kind,
            roomId: effect.roomId,
            error,
          })
        }
      }),
    )
  }

  private async process(effect: ClaimedGridProviderEffect): Promise<void> {
    try {
      await withTimeout(
        (this.runtime.execute ?? executeGridProviderEffect)(effect),
        this.runtime.providerTimeoutMs,
      )
      await (this.runtime.complete ?? completeGridProviderEffect)(effect)
      log.debug("GRID_TRACE phase=provider_effect_completed", {
        effectId: effect.id,
        kind: effect.kind,
        roomId: effect.roomId,
        generation: effect.connectionGeneration,
        attempts: effect.attempts,
      })
    } catch (error) {
      if (isProviderAlreadyAbsent(error)) {
        await (this.runtime.complete ?? completeGridProviderEffect)(effect)
        return
      }
      await (this.runtime.retry ?? retryGridProviderEffect)(effect, error, new Date(this.runtime.now()))
      const attempt = effect.attempts + 1
      const context = {
        effectId: effect.id,
        kind: effect.kind,
        roomId: effect.roomId,
        generation: effect.connectionGeneration,
        attempts: attempt,
        error,
      }
      if (attempt === 1 || attempt === 3 || attempt % 10 === 0) {
        Log.shared.warn("Grid provider effect failed; retry scheduled", context)
      } else {
        log.debug("GRID_TRACE phase=provider_effect_retry_scheduled", context)
      }
    }
  }
}

async function claimGridProviderEffects(input: {
  now: Date
  claimLeaseMs: number
  batchSize: number
}): Promise<ClaimedGridProviderEffect[]> {
  return db.transaction(async (tx) => {
    const effects = await tx
      .select()
      .from(gridProviderEffects)
      .where(
        and(
          lte(gridProviderEffects.availableAt, input.now),
          or(isNull(gridProviderEffects.claimExpiresAt), lte(gridProviderEffects.claimExpiresAt, input.now)),
        ),
      )
      .orderBy(asc(gridProviderEffects.availableAt), asc(gridProviderEffects.id))
      .limit(input.batchSize)
      .for("update", { skipLocked: true })
    if (effects.length === 0) return []

    const claimToken = randomUUID()
    await tx
      .update(gridProviderEffects)
      .set({
        claimToken,
        claimExpiresAt: new Date(input.now.getTime() + input.claimLeaseMs),
        updatedAt: input.now,
      })
      .where(inArray(gridProviderEffects.id, effects.map((effect) => effect.id)))
    return effects.map((effect) => ({ ...effect, claimToken }))
  })
}

async function executeGridProviderEffect(effect: ClaimedGridProviderEffect): Promise<void> {
  const config = getLiveKitGridConfig()
  if (!config) throw new Error("Grid media provider is not configured")
  const connection = {
    roomId: BigInt(effect.roomId),
    generation: effect.connectionGeneration,
  }
  if (effect.kind === "close_connection") {
    await closeGridConnection(connection, config)
    return
  }
  if (effect.kind === "revoke_participant" && effect.userId !== null) {
    await revokeGridParticipantAccess(connection, effect.userId, config, {
      participantIdentity: effect.participantIdentity ?? undefined,
    })
    return
  }
  throw new Error(`Unsupported Grid provider effect: ${effect.kind}`)
}

async function completeGridProviderEffect(effect: ClaimedGridProviderEffect): Promise<void> {
  await db
    .delete(gridProviderEffects)
    .where(and(eq(gridProviderEffects.id, effect.id), eq(gridProviderEffects.claimToken, effect.claimToken)))
}

async function retryGridProviderEffect(
  effect: ClaimedGridProviderEffect,
  error: unknown,
  now: Date,
): Promise<void> {
  const attempts = effect.attempts + 1
  await db
    .update(gridProviderEffects)
    .set({
      attempts,
      claimToken: null,
      claimExpiresAt: null,
      availableAt: new Date(now.getTime() + retryDelayMs(attempts)),
      lastError: describeError(error).slice(0, 500),
      updatedAt: now,
    })
    .where(and(eq(gridProviderEffects.id, effect.id), eq(gridProviderEffects.claimToken, effect.claimToken)))
}

function providerEffectKey(
  kind: GridProviderEffectKind,
  connection: Pick<GridConnection, "roomId" | "generation">,
  participantIdentity?: string,
): string {
  return `${kind}:${connection.roomId}:${connection.generation}:${participantIdentity ?? "room"}`
}

function retryDelayMs(attempts: number): number {
  return Math.min(MAX_RETRY_DELAY_MS, 1_000 * 2 ** Math.min(Math.max(attempts - 1, 0), 9))
}

function positiveInt(value: number | undefined, fallback: number): number {
  return value && Number.isFinite(value) && value > 0 ? Math.floor(value) : fallback
}

function describeError(error: unknown): string {
  return error instanceof Error ? `${error.name}: ${error.message}` : String(error)
}

function isProviderAlreadyAbsent(error: unknown): boolean {
  return error instanceof ServerError && (error.status === 404 || error.code === "not_found")
}

async function withTimeout<T>(operation: Promise<T>, timeoutMs: number): Promise<T> {
  let timeoutId: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      operation,
      new Promise<never>((_, reject) => {
        timeoutId = setTimeout(() => reject(new Error(`Grid provider operation timed out after ${timeoutMs}ms`)), timeoutMs)
      }),
    ])
  } finally {
    if (timeoutId) clearTimeout(timeoutId)
  }
}

let worker: GridProviderEffectWorker | null = null

export function startGridProviderEffectWorker(): GridProviderEffectWorker {
  if (!worker) worker = new GridProviderEffectWorker()
  worker.start()
  return worker
}

export async function stopGridProviderEffectWorker(
  ownedWorker: GridProviderEffectWorker | null =
    worker,
): Promise<void> {
  if (!ownedWorker) return

  await ownedWorker.stop()
  if (worker === ownedWorker) {
    worker = null
  }
}

export function resetGridProviderEffectWorkerForTests(): void {
  worker = null
}
