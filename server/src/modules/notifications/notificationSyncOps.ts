import { internalMessaging } from "@in/server/modules/internalMessaging/service"

/**
 * Recent read/delete state from a user's devices, attached to later message
 * pushes so the iOS notification extension can remove notifications already
 * handled elsewhere. Ops are idempotent and best effort: an unavailable broker
 * only means fewer stale notifications get cleaned up.
 */
export type NotificationSyncOps = {
  read: { threadId: string; upTo: string }[]
  deleted: { threadId: string; ids: string[] }[]
}

export type NotificationSyncOpsStore = {
  command(name: string, args: string[]): Promise<unknown | undefined>
  key(suffix: string): string
}

export const NOTIFICATION_SYNC_OPS_TTL_MS = 24 * 60 * 60 * 1_000
/** Threads tracked per user; the oldest are dropped first. */
export const NOTIFICATION_SYNC_OPS_MAX_ENTRIES = 32
/** Entries attached to one push, newest first. */
export const NOTIFICATION_SYNC_OPS_MAX_ATTACHED = 16
/** Deleted ids kept per thread, newest last. */
export const NOTIFICATION_SYNC_OPS_MAX_DELETED_IDS = 20

const defaultStore: NotificationSyncOpsStore = {
  command: (name, args) => internalMessaging.sendCommand(name, args),
  key: (suffix) => internalMessaging.key(suffix),
}

// Fields: "r:<threadId>" -> "<ts>|<upTo>", "d:<threadId>" -> "<ts>|<id>,<id>".
// Reads keep the highest marker; deletes append up to the id cap. Afterwards the
// hash is trimmed to the entry cap by dropping the oldest timestamps.
const recordScript = `
local key, field, mode, value, now, ttl, maxEntries, maxIds =
  KEYS[1], ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], tonumber(ARGV[6]), tonumber(ARGV[7])
local current = redis.call('HGET', key, field)
local stored = value
if current then
  local previous = string.match(current, '^%d+|(.*)$') or ''
  if mode == 'r' then
    if tonumber(previous) and tonumber(previous) >= tonumber(value) then
      redis.call('PEXPIRE', key, ttl)
      return 0
    end
  else
    local ids = {}
    for id in string.gmatch(previous .. ',' .. value, '[^,]+') do ids[#ids + 1] = id end
    local first = math.max(1, #ids - maxIds + 1)
    stored = table.concat(ids, ',', first, #ids)
  end
end
redis.call('HSET', key, field, now .. '|' .. stored)
redis.call('PEXPIRE', key, ttl)
while redis.call('HLEN', key) > maxEntries do
  local entries = redis.call('HGETALL', key)
  local oldestField, oldestTs = nil, nil
  for i = 1, #entries, 2 do
    local ts = tonumber(string.match(entries[i + 1], '^(%d+)|')) or 0
    if oldestTs == nil or ts < oldestTs then oldestField, oldestTs = entries[i], ts end
  end
  redis.call('HDEL', key, oldestField)
end
return 1
`

const isMessageId = (value: string) => /^[1-9]\d{0,18}$/.test(value)

export class NotificationSyncOpsTracker {
  constructor(
    private readonly store: NotificationSyncOpsStore = defaultStore,
    private readonly now: () => number = Date.now,
  ) {}

  async recordRead(userId: number, threadId: string, upTo: string): Promise<void> {
    if (!isMessageId(upTo)) return
    await this.record(userId, `r:${threadId}`, "r", upTo)
  }

  async recordDeleted(userId: number, threadId: string, ids: string[]): Promise<void> {
    const valid = ids.filter(isMessageId).slice(-NOTIFICATION_SYNC_OPS_MAX_DELETED_IDS)
    if (valid.length === 0) return
    await this.record(userId, `d:${threadId}`, "d", valid.join(","))
  }

  async recent(userId: number): Promise<NotificationSyncOps | undefined> {
    const result = await this.store.command("HGETALL", [this.key(userId)])
    // RESP3 clients return a map; RESP2 a flat field/value list.
    const pairs: [string, unknown][] = Array.isArray(result)
      ? Array.from({ length: Math.floor(result.length / 2) }, (_, i) => [String(result[i * 2]), result[i * 2 + 1]])
      : result && typeof result === "object"
        ? Object.entries(result)
        : []
    if (pairs.length === 0) return undefined
    const cutoff = this.now() - NOTIFICATION_SYNC_OPS_TTL_MS
    const entries: { field: string; ts: number; value: string }[] = []
    for (const [field, raw] of pairs) {
      const match = /^(\d+)\|(.*)$/.exec(String(raw))
      if (!match) continue
      const ts = Number(match[1])
      if (ts < cutoff) continue
      entries.push({ field, ts, value: match[2] ?? "" })
    }
    entries.sort((a, b) => b.ts - a.ts)

    const ops: NotificationSyncOps = { read: [], deleted: [] }
    for (const entry of entries.slice(0, NOTIFICATION_SYNC_OPS_MAX_ATTACHED)) {
      const threadId = entry.field.slice(2)
      if (!threadId) continue
      if (entry.field.startsWith("r:") && isMessageId(entry.value)) {
        ops.read.push({ threadId, upTo: entry.value })
      } else if (entry.field.startsWith("d:")) {
        const ids = entry.value.split(",").filter(isMessageId)
        if (ids.length > 0) ops.deleted.push({ threadId, ids })
      }
    }
    return ops.read.length > 0 || ops.deleted.length > 0 ? ops : undefined
  }

  private async record(userId: number, field: string, mode: "r" | "d", value: string): Promise<void> {
    await this.store.command("EVAL", [
      recordScript,
      "1",
      this.key(userId),
      field,
      mode,
      value,
      String(this.now()),
      String(NOTIFICATION_SYNC_OPS_TTL_MS),
      String(NOTIFICATION_SYNC_OPS_MAX_ENTRIES),
      String(NOTIFICATION_SYNC_OPS_MAX_DELETED_IDS),
    ])
  }

  private key(userId: number): string {
    return this.store.key(`notif-sync:${userId}`)
  }
}

export const notificationSyncOpsTracker = new NotificationSyncOpsTracker()
