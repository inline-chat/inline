import path from "node:path"
import fs from "node:fs"
import { pruneMapToMaxSize } from "openclaw/plugin-sdk/collection-runtime"
import { readJsonFileWithFallback, writeJsonFileAtomically } from "openclaw/plugin-sdk/json-store"
import { getOptionalInlineRuntime } from "../runtime.js"

const TTL_MS = 7 * 24 * 60 * 60 * 1000
const MAX_ENTRIES = 5000
const PERSISTENT_MAX_ENTRIES = 2000
const STORE_VERSION = 1
const PERSISTENT_NAMESPACE = "inline.reply-thread-routes"
const INLINE_REPLY_THREAD_ROUTE_KEY = Symbol.for("openclaw.inlineReplyThreadRoutes")

export type InlineReplyThreadRouteRecord = {
  accountId: string
  parentChatId: string
  threadId: string
  createdAt: number
  updatedAt: number
  parentMessageId?: string
  title?: string
  threadLabel?: string
  agentId?: string
}

type InlineReplyThreadRouteStore = {
  register(
    key: string,
    value: InlineReplyThreadRouteRecord,
    opts?: { ttlMs?: number },
  ): Promise<void>
  lookup(key: string): Promise<InlineReplyThreadRouteRecord | undefined>
}

type RouteCacheEntry = {
  value: InlineReplyThreadRouteRecord
  updatedAt: number
}

type StoredRouteState = {
  version: number
  routes: Record<string, InlineReplyThreadRouteRecord>
}

type RouteState = {
  memory: Map<string, RouteCacheEntry>
  fileWrites: Map<string, Promise<void>>
}

const DEFAULT_AGENT_KEY = "__any__"
const DEFAULT_STORE_KEY = "__default__"

let routeState: RouteState | undefined
let persistentStore: InlineReplyThreadRouteStore | undefined
let persistentStoreDisabled = false

function getRouteState(): RouteState {
  if (routeState) return routeState
  const globalStore = globalThis as Record<PropertyKey, unknown>
  const existing = globalStore[INLINE_REPLY_THREAD_ROUTE_KEY] as RouteState | undefined
  routeState = existing ?? {
    memory: new Map<string, RouteCacheEntry>(),
    fileWrites: new Map<string, Promise<void>>(),
  }
  globalStore[INLINE_REPLY_THREAD_ROUTE_KEY] = routeState
  return routeState
}

function normalizePositiveId(raw: bigint | string | number | null | undefined): string | undefined {
  if (raw == null) return undefined
  if (typeof raw === "bigint") return raw >= 0n ? String(raw) : undefined
  if (typeof raw === "number") {
    return Number.isInteger(raw) && raw >= 0 ? String(raw) : undefined
  }
  const trimmed = raw.trim()
  if (!/^\d+$/.test(trimmed)) return undefined
  return trimmed
}

function normalizeOptionalText(raw: string | null | undefined): string | undefined {
  const trimmed = raw?.trim()
  return trimmed || undefined
}

function safePathSegment(value: string): string {
  return value.trim().replace(/[^a-z0-9._-]+/gi, "_").slice(0, 80) || "global"
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function readString(record: Record<string, unknown>, key: string): string | undefined {
  const value = record[key]
  return typeof value === "string" && value.trim() ? value.trim() : undefined
}

function readTimestamp(record: Record<string, unknown>, key: string, fallback: number): number {
  const value = record[key]
  return typeof value === "number" && Number.isFinite(value) ? Math.max(0, Math.floor(value)) : fallback
}

function normalizeRecord(value: unknown): InlineReplyThreadRouteRecord | null {
  if (!isRecord(value)) return null
  const accountId = readString(value, "accountId")
  const parentChatId = normalizePositiveId(readString(value, "parentChatId"))
  const threadId = normalizePositiveId(readString(value, "threadId"))
  if (!accountId || !parentChatId || !threadId) return null
  const now = Date.now()
  const parentMessageId = normalizePositiveId(readString(value, "parentMessageId"))
  const title = normalizeOptionalText(readString(value, "title"))
  const threadLabel = normalizeOptionalText(readString(value, "threadLabel"))
  const agentId = normalizeOptionalText(readString(value, "agentId"))
  return {
    accountId,
    parentChatId,
    threadId,
    createdAt: readTimestamp(value, "createdAt", now),
    updatedAt: readTimestamp(value, "updatedAt", now),
    ...(parentMessageId ? { parentMessageId } : {}),
    ...(title ? { title } : {}),
    ...(threadLabel ? { threadLabel } : {}),
    ...(agentId ? { agentId } : {}),
  }
}

function isExpired(record: InlineReplyThreadRouteRecord, now: number): boolean {
  return now - record.updatedAt > TTL_MS
}

function reportRouteStateError(error: unknown): void {
  try {
    getOptionalInlineRuntime()
      ?.logging.getChildLogger({ plugin: "inline", feature: "reply-thread-route-state" })
      .warn("Inline reply-thread route state failed", { error: String(error) })
  } catch {
    // Best effort only: route cache persistence must never break message handling.
  }
}

function disablePersistentStore(error: unknown): void {
  persistentStoreDisabled = true
  persistentStore = undefined
  if (!String(error).includes("openKeyedStore is only available")) {
    reportRouteStateError(error)
  }
}

function getPersistentStore(): InlineReplyThreadRouteStore | undefined {
  if (persistentStoreDisabled) return undefined
  if (persistentStore) return persistentStore

  const openKeyedStore = getOptionalInlineRuntime()?.state?.openKeyedStore
  if (typeof openKeyedStore !== "function") return undefined

  try {
    persistentStore = openKeyedStore<InlineReplyThreadRouteRecord>({
      namespace: PERSISTENT_NAMESPACE,
      maxEntries: PERSISTENT_MAX_ENTRIES,
      defaultTtlMs: TTL_MS,
    })
    return persistentStore
  } catch (error) {
    disablePersistentStore(error)
    return undefined
  }
}

function resolveRoutesPath(accountId: string): string | undefined {
  const resolveStateDir = getOptionalInlineRuntime()?.state?.resolveStateDir
  if (typeof resolveStateDir !== "function") return undefined
  return path.join(
    resolveStateDir(),
    "inline",
    "reply-thread-routes",
    `${safePathSegment(accountId)}.json`,
  )
}

function activeKey(accountId: string, parentChatId: string, agentId?: string): string {
  return `${accountId}:parent:${parentChatId}:agent:${agentId || DEFAULT_AGENT_KEY}`
}

function messageKey(accountId: string, parentChatId: string, parentMessageId: string): string {
  return `${accountId}:parent:${parentChatId}:message:${parentMessageId}`
}

function threadKey(accountId: string, threadId: string): string {
  return `${accountId}:thread:${threadId}`
}

function keysForRecord(record: InlineReplyThreadRouteRecord): string[] {
  const keys = new Set<string>()
  keys.add(threadKey(record.accountId, record.threadId))
  if (record.parentMessageId) {
    keys.add(messageKey(record.accountId, record.parentChatId, record.parentMessageId))
  }
  if (record.agentId) {
    keys.add(activeKey(record.accountId, record.parentChatId, record.agentId))
  }
  keys.add(activeKey(record.accountId, record.parentChatId))
  return [...keys]
}

function keysForLookup(params: {
  accountId: string
  parentChatId: string
  parentMessageId?: string
  agentId?: string
}): string[] {
  const keys = new Set<string>()
  if (params.parentMessageId) {
    keys.add(messageKey(params.accountId, params.parentChatId, params.parentMessageId))
    return [...keys]
  }
  if (params.agentId) {
    keys.add(activeKey(params.accountId, params.parentChatId, params.agentId))
  }
  keys.add(activeKey(params.accountId, params.parentChatId))
  return [...keys]
}

async function lookupInlineReplyThreadRouteByKeys(
  accountId: string,
  keys: string[],
): Promise<InlineReplyThreadRouteRecord | null> {
  const now = Date.now()

  for (const key of keys) {
    const cached = getMemory(key, now)
    if (cached) return cached
  }

  const store = getPersistentStore()
  if (store) {
    for (const key of keys) {
      try {
        const found = await store.lookup(key)
        const normalized = normalizeRecord(found)
        if (normalized && !isExpired(normalized, now)) {
          setMemory(key, normalized, now)
          return normalized
        }
      } catch (error) {
        disablePersistentStore(error)
        break
      }
    }
  }

  const fileRoutes = await readFileRoutes(accountId)
  for (const key of keys) {
    const found = fileRoutes.get(key)
    const normalized = normalizeRecord(found)
    if (normalized) {
      setMemory(key, normalized, now)
      return normalized
    }
  }

  return null
}

function setMemory(key: string, value: InlineReplyThreadRouteRecord, now: number): void {
  const memory = getRouteState().memory
  memory.delete(key)
  memory.set(key, { value, updatedAt: now })
  pruneMapToMaxSize(memory, MAX_ENTRIES)
}

function getMemory(key: string, now: number): InlineReplyThreadRouteRecord | undefined {
  const memory = getRouteState().memory
  const entry = memory.get(key)
  if (!entry) return undefined
  if (now - entry.updatedAt > TTL_MS || isExpired(entry.value, now)) {
    memory.delete(key)
    return undefined
  }
  memory.delete(key)
  memory.set(key, { ...entry, updatedAt: now })
  return entry.value
}

async function readFileRoutes(accountId: string): Promise<Map<string, InlineReplyThreadRouteRecord>> {
  const filePath = resolveRoutesPath(accountId)
  if (!filePath) return new Map()
  const fallback: StoredRouteState = { version: STORE_VERSION, routes: {} }
  const now = Date.now()
  try {
    const { value } = await readJsonFileWithFallback(filePath, fallback)
    if (value.version !== STORE_VERSION || !isRecord(value.routes)) {
      return new Map()
    }
    const routes = new Map<string, InlineReplyThreadRouteRecord>()
    for (const [key, raw] of Object.entries(value.routes)) {
      const route = normalizeRecord(raw)
      if (route && !isExpired(route, now)) routes.set(key, route)
    }
    return routes
  } catch (error) {
    reportRouteStateError(error)
    return new Map()
  }
}

async function writeFileRoutes(
  accountId: string,
  routes: Map<string, InlineReplyThreadRouteRecord>,
): Promise<void> {
  const filePath = resolveRoutesPath(accountId)
  if (!filePath) return
  const pruned = [...routes.entries()]
    .sort((left, right) => right[1].updatedAt - left[1].updatedAt)
    .slice(0, PERSISTENT_MAX_ENTRIES)
  await writeJsonFileAtomically(filePath, {
    version: STORE_VERSION,
    routes: Object.fromEntries(pruned),
  } satisfies StoredRouteState)
}

function rememberFileRoutes(params: {
  accountId: string
  keys: string[]
  record: InlineReplyThreadRouteRecord
}): void {
  const state = getRouteState()
  const queueKey = params.accountId || DEFAULT_STORE_KEY
  const previous = state.fileWrites.get(queueKey) ?? Promise.resolve()
  const next = previous
    .catch(() => undefined)
    .then(async () => {
      const routes = await readFileRoutes(params.accountId)
      for (const key of params.keys) {
        routes.set(key, params.record)
      }
      await writeFileRoutes(params.accountId, routes)
    })
  state.fileWrites.set(queueKey, next)
  const cleanup = () => {
    if (state.fileWrites.get(queueKey) === next) {
      state.fileWrites.delete(queueKey)
    }
  }
  next.then(cleanup, cleanup)
  next.catch(reportRouteStateError)
}

export function rememberInlineReplyThreadRoute(params: {
  accountId: string
  parentChatId: bigint | string
  threadId: bigint | string
  parentMessageId?: bigint | string | null
  title?: string | null
  threadLabel?: string | null
  agentId?: string | null
}): InlineReplyThreadRouteRecord | null {
  const accountId = params.accountId.trim()
  const parentChatId = normalizePositiveId(params.parentChatId)
  const threadId = normalizePositiveId(params.threadId)
  if (!accountId || !parentChatId || !threadId) return null

  const now = Date.now()
  const parentMessageId = normalizePositiveId(params.parentMessageId)
  const title = normalizeOptionalText(params.title)
  const threadLabel = normalizeOptionalText(params.threadLabel)
  const agentId = normalizeOptionalText(params.agentId)
  const record: InlineReplyThreadRouteRecord = {
    accountId,
    parentChatId,
    threadId,
    createdAt: now,
    updatedAt: now,
    ...(parentMessageId ? { parentMessageId } : {}),
    ...(title ? { title } : {}),
    ...(threadLabel ? { threadLabel } : {}),
    ...(agentId ? { agentId } : {}),
  }
  const keys = keysForRecord(record)
  for (const key of keys) {
    setMemory(key, record, now)
  }

  const store = getPersistentStore()
  if (store) {
    for (const key of keys) {
      void store.register(key, record, { ttlMs: TTL_MS }).catch(disablePersistentStore)
    }
    return record
  }

  rememberFileRoutes({ accountId, keys, record })
  return record
}

export async function lookupInlineReplyThreadRoute(params: {
  accountId: string
  parentChatId: bigint | string
  parentMessageId?: bigint | string | null
  agentId?: string | null
}): Promise<InlineReplyThreadRouteRecord | null> {
  const accountId = params.accountId.trim()
  const parentChatId = normalizePositiveId(params.parentChatId)
  if (!accountId || !parentChatId) return null

  const parentMessageId = normalizePositiveId(params.parentMessageId)
  const agentId = normalizeOptionalText(params.agentId)
  const keys = keysForLookup({
    accountId,
    parentChatId,
    ...(parentMessageId ? { parentMessageId } : {}),
    ...(agentId ? { agentId } : {}),
  })
  return await lookupInlineReplyThreadRouteByKeys(accountId, keys)
}

export async function lookupInlineReplyThreadRouteByThreadId(params: {
  accountId: string
  threadId: bigint | string | null
}): Promise<InlineReplyThreadRouteRecord | null> {
  const accountId = params.accountId.trim()
  const threadId = normalizePositiveId(params.threadId)
  if (!accountId || !threadId) return null

  return await lookupInlineReplyThreadRouteByKeys(accountId, [threadKey(accountId, threadId)])
}

export function clearInlineReplyThreadRouteCacheForTest(): void {
  getRouteState().memory.clear()
  getRouteState().fileWrites.clear()
  persistentStore = undefined
  persistentStoreDisabled = false
  const resolveStateDir = getOptionalInlineRuntime()?.state?.resolveStateDir
  if (typeof resolveStateDir === "function") {
    fs.rmSync(path.join(resolveStateDir(), "inline", "reply-thread-routes"), {
      force: true,
      recursive: true,
    })
  }
}
