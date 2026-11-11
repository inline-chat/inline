import { db } from "@in/server/db"
import { chatAccessState } from "@in/server/db/schema"
import { Log } from "@in/server/utils/log"

const log = new Log("authorization.chatAccessTrust")

/** Writers keep `chat_access` current unless this kill switch is set. */
export const isChatAccessSyncEnabled = (): boolean => process.env["INLINE_CHAT_ACCESS_SYNC"] !== "off"

/** How long a host may keep trusting the marker after it was cleared elsewhere. */
export const CHAT_ACCESS_TRUST_REFRESH_MS = 30_000

/**
 * Committed-state readers may answer from `chat_access` only while every
 * writer keeps it current. That holds when this host syncs, reads are not
 * switched off, and the backfill marker exists. A host started with sync off
 * deletes the marker, and the next full verifier pass on a syncing host
 * recreates it, so no reader trusts rows written across a sync gap.
 */
export const isChatAccessReadEnabled = (): boolean =>
  isChatAccessSyncEnabled() && process.env["INLINE_CHAT_ACCESS_READS"] !== "off"

let trusted = false
let refreshedAtMs = 0
let refreshing: Promise<void> | undefined
let timer: ReturnType<typeof setInterval> | undefined

/**
 * Synchronous gate for hot paths. Only a host that started the refresh loop
 * (production, through the verifier process) can open it; a cold, failed or
 * stalled refresh falls back to the projection.
 */
export function isStoredChatAccessTrusted(): boolean {
  if (!isChatAccessReadEnabled()) return false
  if (Date.now() - refreshedAtMs > CHAT_ACCESS_TRUST_REFRESH_MS * 2) return false
  return trusted
}

export async function refreshChatAccessTrust(): Promise<boolean> {
  if (!isChatAccessReadEnabled()) {
    trusted = false
    return false
  }
  refreshing ??= (async () => {
    try {
      const [state] = await db.select({ id: chatAccessState.id }).from(chatAccessState).limit(1)
      const next = state !== undefined
      if (next !== trusted) log.info(next ? "Chat access reads use the table" : "Chat access reads use the projection")
      trusted = next
      refreshedAtMs = Date.now()
    } catch (error) {
      trusted = false
      log.warn("Chat access trust refresh failed; reads use the projection", { error })
    } finally {
      refreshing = undefined
    }
  })()
  await refreshing
  return trusted
}

/** A host that does not sync must make every host distrust the table until a full repair. */
export async function revokeChatAccessTrustIfSyncDisabled(): Promise<void> {
  if (isChatAccessSyncEnabled()) return
  try {
    await db.delete(chatAccessState)
    log.warn("Chat access sync is off; cleared the backfill marker so reads use the projection")
  } catch (error) {
    log.error("Chat access sync is off but the backfill marker could not be cleared", { error })
  }
}

export function startChatAccessTrustRefresh(): () => void {
  void refreshChatAccessTrust()
  timer ??= setInterval(() => { void refreshChatAccessTrust() }, CHAT_ACCESS_TRUST_REFRESH_MS)
  timer.unref?.()
  return () => {
    if (timer) clearInterval(timer)
    timer = undefined
  }
}

/** Tests only. */
export function setChatAccessTrustForTests(value: boolean): void {
  trusted = value
  refreshedAtMs = value ? Date.now() : 0
}
