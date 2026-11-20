import { db } from "@in/server/db"
import { chatAccessState } from "@in/server/db/schema"
import { Log } from "@in/server/utils/log"

const log = new Log("authorization.chatAccessTrust")

/** Writers keep `chat_access` current unless this kill switch is set. */
export const isChatAccessSyncEnabled = (): boolean => process.env["INLINE_CHAT_ACCESS_SYNC"] !== "off"

/** How long a host may keep trusting the marker after it was cleared elsewhere. */
export const CHAT_ACCESS_TRUST_REFRESH_MS = 30_000

/** Retained for diagnostics and write compatibility with servers that still serve table reads. */
export const isChatAccessReadEnabled = (): boolean =>
  isChatAccessSyncEnabled() && process.env["INLINE_CHAT_ACCESS_READS"] !== "off"

let trusted = false
let refreshedAtMs = 0
let refreshing: Promise<void> | undefined
let timer: ReturnType<typeof setInterval> | undefined

/** A recently completed backfill makes drift sampling useful. It cannot attest to other writers. */
export function canSampleStoredChatAccess(): boolean {
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
      if (next !== trusted) log.info(next ? "Chat access drift sampling enabled" : "Chat access drift sampling paused")
      trusted = next
      refreshedAtMs = Date.now()
    } catch (error) {
      trusted = false
      log.warn("Chat access marker refresh failed; drift sampling paused", { error })
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
