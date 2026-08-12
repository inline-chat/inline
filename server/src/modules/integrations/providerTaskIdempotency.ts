import { db } from "@in/server/db"
import { externalTasks, type DbExternalTask } from "@in/server/db/schema"
import { decrypt } from "@in/server/modules/encryption/encryption"
import { and, eq } from "drizzle-orm"

export type ProviderTaskApplication = "linear" | "notion"

export type ProviderTaskIdentity = {
  application: ProviderTaskApplication
  assignedUserId: bigint
  sourceMessageId: bigint
  connectorSpaceId: number
}

const PROVIDER_TASK_IDEMPOTENCY_CONSTRAINT =
  "external_tasks_provider_user_source_space_unique"

export async function findExistingProviderTask(
  identity: ProviderTaskIdentity,
): Promise<DbExternalTask | undefined> {
  const [task] = await db
    .select()
    .from(externalTasks)
    .where(and(
      eq(externalTasks.application, identity.application),
      eq(externalTasks.assignedUserId, identity.assignedUserId),
      eq(externalTasks.sourceMessageId, identity.sourceMessageId),
      eq(externalTasks.connectorSpaceId, identity.connectorSpaceId),
    ))
    .limit(1)
  return task
}

export function isProviderTaskIdempotencyConflict(error: unknown): boolean {
  if (!error || typeof error !== "object") return false

  const record = error as Record<string, unknown>
  return (
    record["code"] === "23505" &&
    (record["constraint"] === PROVIDER_TASK_IDEMPOTENCY_CONSTRAINT ||
      record["constraint_name"] === PROVIDER_TASK_IDEMPOTENCY_CONSTRAINT ||
      String(record["message"] ?? "").includes(PROVIDER_TASK_IDEMPOTENCY_CONSTRAINT))
  )
}

export function linearTaskReplayResponse(
  task: DbExternalTask | undefined,
): { link?: string } | undefined {
  return task?.url ? { link: task.url } : undefined
}

export function notionTaskReplayResponse(
  task: DbExternalTask | undefined,
): { url: string; taskTitle: string | null } | undefined {
  if (!task?.url) return undefined

  let taskTitle: string | null = null
  if (task.title && task.titleIv && task.titleTag) {
    try {
      taskTitle = decrypt({
        encrypted: task.title,
        iv: task.titleIv,
        authTag: task.titleTag,
      })
    } catch {
      // The URL is still a valid durable result if legacy title data is unreadable.
    }
  }

  return { url: task.url, taskTitle }
}
