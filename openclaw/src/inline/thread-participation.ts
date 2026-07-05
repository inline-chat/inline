import path from "node:path"
import { resolveGlobalDedupeCache } from "openclaw/plugin-sdk/dedupe-runtime"
import { createPersistentDedupe, type PersistentDedupe } from "openclaw/plugin-sdk/persistent-dedupe"
import { getOptionalInlineRuntime } from "../runtime.js"

const TTL_MS = 24 * 60 * 60 * 1000
const MAX_ENTRIES = 5000
const PERSISTENT_MAX_ENTRIES = 1000
const PERSISTENT_NAMESPACE = "inline.thread-participation"
const PERSISTENT_DEDUPE_NAMESPACE = "participation"
const INLINE_THREAD_PARTICIPATION_KEY = Symbol.for("openclaw.inlineThreadParticipation")

type InlineThreadParticipationRecord = {
  agentId?: string
  repliedAt: number
}

type InlineThreadParticipationStore = {
  register(
    key: string,
    value: InlineThreadParticipationRecord,
    opts?: { ttlMs?: number },
  ): Promise<void>
  lookup(key: string): Promise<InlineThreadParticipationRecord | undefined>
}

const threadParticipation = resolveGlobalDedupeCache(INLINE_THREAD_PARTICIPATION_KEY, {
  ttlMs: TTL_MS,
  maxSize: MAX_ENTRIES,
})

let persistentStore: InlineThreadParticipationStore | undefined
let persistentStoreDisabled = false
let persistentDedupe: PersistentDedupe | undefined

function makeKey(accountId: string, parentChatId: bigint, threadId: bigint): string {
  return `${accountId}:${String(parentChatId)}:${String(threadId)}`
}

function safePathSegment(value: string): string {
  return value.trim().replace(/[^a-z0-9._-]+/gi, "_").slice(0, 80) || "global"
}

function isExpectedOpenKeyedStoreUnavailable(error: unknown): boolean {
  return String(error).includes("openKeyedStore is only available")
}

function reportPersistentThreadParticipationError(error: unknown): void {
  try {
    getOptionalInlineRuntime()
      ?.logging.getChildLogger({ plugin: "inline", feature: "thread-participation-state" })
      .warn("Inline persistent thread participation state failed", { error: String(error) })
  } catch {
    // Best effort only: persistent state must never break Inline message handling.
  }
}

function disablePersistentThreadParticipation(error: unknown): void {
  persistentStoreDisabled = true
  persistentStore = undefined
  if (!isExpectedOpenKeyedStoreUnavailable(error)) {
    reportPersistentThreadParticipationError(error)
  }
}

function getPersistentThreadParticipationStore(): InlineThreadParticipationStore | undefined {
  if (persistentStoreDisabled) return undefined
  if (persistentStore) return persistentStore

  const runtime = getOptionalInlineRuntime()
  const openKeyedStore = runtime?.state?.openKeyedStore
  if (typeof openKeyedStore !== "function") return undefined

  try {
    persistentStore = openKeyedStore<InlineThreadParticipationRecord>({
      namespace: PERSISTENT_NAMESPACE,
      maxEntries: PERSISTENT_MAX_ENTRIES,
      defaultTtlMs: TTL_MS,
    })
    return persistentStore
  } catch (error) {
    disablePersistentThreadParticipation(error)
    return undefined
  }
}

function getPersistentThreadParticipationDedupe(): PersistentDedupe | undefined {
  if (persistentDedupe) return persistentDedupe

  const resolveStateDir = getOptionalInlineRuntime()?.state?.resolveStateDir
  if (typeof resolveStateDir !== "function") return undefined

  try {
    const stateDir = resolveStateDir()
    persistentDedupe = createPersistentDedupe({
      ttlMs: TTL_MS,
      memoryMaxSize: MAX_ENTRIES,
      fileMaxEntries: PERSISTENT_MAX_ENTRIES,
      resolveFilePath: (namespace) =>
        path.join(
          stateDir,
          "inline",
          "thread-participation",
          `${safePathSegment(namespace)}.json`,
        ),
      onDiskError: reportPersistentThreadParticipationError,
    })
    return persistentDedupe
  } catch (error) {
    reportPersistentThreadParticipationError(error)
    return undefined
  }
}

function rememberPersistentThreadParticipation(params: { key: string; agentId?: string }): void {
  const store = getPersistentThreadParticipationStore()
  if (store) {
    void store
      .register(
        params.key,
        {
          ...(params.agentId ? { agentId: params.agentId } : {}),
          repliedAt: Date.now(),
        },
        { ttlMs: TTL_MS },
      )
      .catch(disablePersistentThreadParticipation)
    return
  }

  void getPersistentThreadParticipationDedupe()
    ?.checkAndRecord(params.key, { namespace: PERSISTENT_DEDUPE_NAMESPACE })
    .catch(reportPersistentThreadParticipationError)
}

async function lookupPersistentThreadParticipation(key: string): Promise<boolean> {
  const store = getPersistentThreadParticipationStore()
  if (!store) {
    return (
      (await getPersistentThreadParticipationDedupe()
        ?.hasRecent(key, { namespace: PERSISTENT_DEDUPE_NAMESPACE })
        .catch((error) => {
          reportPersistentThreadParticipationError(error)
          return false
        })) ?? false
    )
  }

  try {
    return Boolean(await store.lookup(key))
  } catch (error) {
    disablePersistentThreadParticipation(error)
    return false
  }
}

export function recordInlineThreadParticipation(
  accountId: string,
  parentChatId: bigint,
  threadId: bigint,
  opts?: { agentId?: string },
): void {
  if (!accountId || parentChatId < 0n || threadId < 0n) return

  const key = makeKey(accountId, parentChatId, threadId)
  threadParticipation.check(key)
  rememberPersistentThreadParticipation({
    key,
    ...(opts?.agentId ? { agentId: opts.agentId } : {}),
  })
}

export async function hasInlineThreadParticipationWithPersistence(params: {
  accountId: string
  parentChatId: bigint
  threadId: bigint
}): Promise<boolean> {
  if (!params.accountId || params.parentChatId < 0n || params.threadId < 0n) return false

  const key = makeKey(params.accountId, params.parentChatId, params.threadId)
  if (threadParticipation.peek(key)) return true

  const found = await lookupPersistentThreadParticipation(key)
  if (found) threadParticipation.check(key)
  return found
}

export function clearInlineThreadParticipationCacheForTest(): void {
  threadParticipation.clear()
  persistentStore = undefined
  persistentStoreDisabled = false
  persistentDedupe = undefined
}
