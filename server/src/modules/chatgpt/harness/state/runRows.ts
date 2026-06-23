import { randomUUID } from "node:crypto"
import { and, eq, inArray, isNull, lt, or, sql } from "drizzle-orm"
import { db } from "@in/server/db"
import { internalAgentRuns, type DbInternalAgentRun } from "@in/server/db/schema"
import { CHATGPT_AGENT_KEY } from "@inline-chat/agent-chatgpt"

export type InternalAgentRunStatus =
  | "pending"
  | "debouncing"
  | "running"
  | "streaming"
  | "waiting_for_tool"
  | "succeeded"
  | "failed"
  | "cancel_requested"
  | "canceled"
  | "interrupted"

export const ACTIVE_RUN_STATUSES: InternalAgentRunStatus[] = [
  "pending",
  "debouncing",
  "running",
  "streaming",
  "waiting_for_tool",
  "cancel_requested",
]

export type CreateRunInput = {
  readonly runKey: string
  readonly actorUserId: number
  readonly botUserId: number
  readonly chatId: number
  readonly threadRootMsgId?: number | null
  readonly triggerMsgGlobalId: bigint
}

export async function createChatgptRun(input: CreateRunInput): Promise<DbInternalAgentRun | undefined> {
  const runId = `chatgpt_${randomUUID()}`
  const [row] = await db
    .insert(internalAgentRuns)
    .values({
      id: runId,
      agentKey: CHATGPT_AGENT_KEY,
      runKey: input.runKey,
      scopeType: "user",
      scopeUserId: input.actorUserId,
      actorUserId: input.actorUserId,
      botUserId: input.botUserId,
      chatId: input.chatId,
      threadRootMsgId: input.threadRootMsgId ?? null,
      triggerMsgGlobalId: input.triggerMsgGlobalId,
      status: "pending",
      attempt: 0,
    })
    .onConflictDoNothing()
    .returning()

  return row
}

export async function getChatgptRun(runId: string): Promise<DbInternalAgentRun | undefined> {
  const [row] = await db.select().from(internalAgentRuns).where(eq(internalAgentRuns.id, runId)).limit(1)
  return row
}

export async function updateRunStatus(input: {
  readonly runId: string
  readonly status: InternalAgentRunStatus
  readonly errorCode?: string | null
  readonly errorMessage?: string | null
  readonly visibleTextLength?: number
}): Promise<void> {
  const now = new Date()
  await db
    .update(internalAgentRuns)
    .set({
      status: input.status,
      errorCode: input.errorCode,
      errorMessage: input.errorMessage?.slice(0, 1000),
      lastVisibleTextLength: input.visibleTextLength,
      completedAt: isTerminal(input.status) ? now : undefined,
      updatedAt: now,
    })
    .where(eq(internalAgentRuns.id, input.runId))
}

export async function markRunDebouncing(runId: string): Promise<void> {
  await db
    .update(internalAgentRuns)
    .set({ status: "debouncing", updatedAt: new Date() })
    .where(eq(internalAgentRuns.id, runId))
}

export async function claimRun(input: {
  readonly runId: string
  readonly leaseOwner: string
  readonly leaseMs: number
}): Promise<DbInternalAgentRun | undefined> {
  const now = new Date()
  const [row] = await db
    .update(internalAgentRuns)
    .set({
      status: "running",
      startedAt: now,
      heartbeatAt: now,
      leaseOwner: input.leaseOwner,
      leaseExpiresAt: new Date(now.getTime() + input.leaseMs),
      attempt: sql`${internalAgentRuns.attempt} + 1`,
      updatedAt: now,
    })
    .where(eq(internalAgentRuns.id, input.runId))
    .returning()

  if (!row) {
    return undefined
  }

  return row
}

export async function heartbeatRun(input: {
  readonly runId: string
  readonly leaseOwner: string
  readonly leaseMs: number
}): Promise<void> {
  const now = new Date()
  await db
    .update(internalAgentRuns)
    .set({
      heartbeatAt: now,
      leaseExpiresAt: new Date(now.getTime() + input.leaseMs),
      updatedAt: now,
    })
    .where(and(eq(internalAgentRuns.id, input.runId), eq(internalAgentRuns.leaseOwner, input.leaseOwner)))
}

export async function setRunOutputMessage(input: {
  readonly runId: string
  readonly outputMsgGlobalId: bigint
}): Promise<void> {
  await db
    .update(internalAgentRuns)
    .set({
      outputMsgGlobalId: input.outputMsgGlobalId,
      updatedAt: new Date(),
    })
    .where(eq(internalAgentRuns.id, input.runId))
}

export async function markRunStreaming(input: {
  readonly runId: string
  readonly visibleTextLength: number
}): Promise<void> {
  await db
    .update(internalAgentRuns)
    .set({
      status: "streaming",
      lastEditAt: new Date(),
      lastVisibleTextLength: input.visibleTextLength,
      updatedAt: new Date(),
    })
    .where(eq(internalAgentRuns.id, input.runId))
}

export async function requestCancelRunsForKey(input: {
  readonly runKey: string
  readonly actorUserId: number
  readonly exceptRunId?: string
}): Promise<string[]> {
  const rows = await db
    .update(internalAgentRuns)
    .set({
      status: "cancel_requested",
      updatedAt: new Date(),
    })
    .where(
      and(
        eq(internalAgentRuns.agentKey, CHATGPT_AGENT_KEY),
        eq(internalAgentRuns.runKey, input.runKey),
        eq(internalAgentRuns.actorUserId, input.actorUserId),
        inArray(internalAgentRuns.status, ACTIVE_RUN_STATUSES),
      ),
    )
    .returning({ id: internalAgentRuns.id })

  return rows.map((row) => row.id).filter((id) => id !== input.exceptRunId)
}

export async function findRecoverableChatgptRuns(input: {
  readonly now: Date
  readonly limit?: number
}): Promise<DbInternalAgentRun[]> {
  return db
    .select()
    .from(internalAgentRuns)
    .where(
      and(
        eq(internalAgentRuns.agentKey, CHATGPT_AGENT_KEY),
        inArray(internalAgentRuns.status, ACTIVE_RUN_STATUSES),
        or(isNull(internalAgentRuns.leaseExpiresAt), lt(internalAgentRuns.leaseExpiresAt, input.now)),
      ),
    )
    .limit(input.limit ?? 50)
}

function isTerminal(status: InternalAgentRunStatus): boolean {
  return status === "succeeded" || status === "failed" || status === "canceled" || status === "interrupted"
}
