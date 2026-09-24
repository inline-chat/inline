import { ChatId, SpaceId, UserId } from "@in/server/core/schema/identifiers"
import { internalMessaging } from "@in/server/modules/internalMessaging/service"
import { clearChatInfoCache, invalidateChatInfoCache } from "./chatInfo"
import { clearSpaceCache, invalidateSpaceCache } from "./spaceCache"
import { clearUserNameCache, invalidateUserNameCache } from "./userNames"
import { clearUserPhotoCache, invalidateUserPhotoCache } from "./userPhotos"
import { clearUserSettingsCache, invalidateUserSettingsCache } from "./userSettings"
import { AccessGuardsCache } from "@in/server/modules/authorization/accessGuardsCache"
import { connectionManager } from "@in/server/ws/connections"
import { outboundPublications } from "@in/server/modules/internalMessaging/outbound"

type CacheKey =
  | { kind: "userSettings"; userId: number }
  | { kind: "userDisplay"; userId: number }
  | { kind: "chatMetadata"; chatId: number }
  | { kind: "spaceMetadata"; spaceId: number }
  | { kind: "spaceRecipients"; spaceId: number }

const MAX_CONCURRENT_ACCESS_REFRESHES = 16
const MAX_PENDING_ACCESS_REFRESHES = 368

class AccessRefreshLimiter {
  private active = 0
  private readonly waiters: (() => void)[] = []

  async run(work: () => Promise<void>): Promise<void> {
    if (this.active < MAX_CONCURRENT_ACCESS_REFRESHES) {
      this.active += 1
    } else {
      if (this.waiters.length >= MAX_PENDING_ACCESS_REFRESHES) return
      await new Promise<void>((resolve) => this.waiters.push(resolve))
    }

    try {
      await work()
    } finally {
      const next = this.waiters.shift()
      if (next) next()
      else this.active -= 1
    }
  }
}

const accessRefreshLimiter = new AccessRefreshLimiter()

/**
 * Broker delivery owns this work: each chunk is awaited before the next one,
 * and ConnectionManager coalesces duplicate user/space reads across events.
 */
export const refreshSpaceMemberships = async (userIds: readonly number[], spaceId: number): Promise<void> => {
  for (let offset = 0; offset < userIds.length; offset += MAX_CONCURRENT_ACCESS_REFRESHES) {
    const chunk = userIds.slice(offset, offset + MAX_CONCURRENT_ACCESS_REFRESHES)
    await Promise.allSettled(chunk.map((userId) => accessRefreshLimiter.run(
      () => connectionManager.refreshSpaceMembership(userId, spaceId),
    )))
  }
}

export function invalidateLocalCache(key: CacheKey): void {
  switch (key.kind) {
    case "userSettings": invalidateUserSettingsCache(key.userId); break
    case "userDisplay": invalidateUserNameCache(key.userId); invalidateUserPhotoCache(key.userId); break
    case "chatMetadata": invalidateChatInfoCache(key.chatId); break
    case "spaceMetadata": invalidateSpaceCache(key.spaceId); break
    case "spaceRecipients": invalidateSpaceCache(key.spaceId); clearChatInfoCache(); break
  }
}

export function clearClusterCaches(): void {
  clearUserSettingsCache()
  clearUserNameCache()
  clearUserPhotoCache()
  clearChatInfoCache()
  clearSpaceCache()
  // A missed access-change hint must never leave a ten-minute positive
  // authorization entry behind after a broker continuity gap.
  AccessGuardsCache.resetAll()
}

/** Invoke only after the owning transaction has committed. */
export function publishCacheInvalidation(key: CacheKey): void {
  invalidateLocalCache(key)
  const cache = key.kind === "userSettings" || key.kind === "userDisplay"
    ? { kind: key.kind, userId: UserId.make(key.userId) }
    : key.kind === "chatMetadata"
      ? { kind: key.kind, chatId: ChatId.make(key.chatId) }
      : { kind: key.kind, spaceId: SpaceId.make(key.spaceId) }
  const id = "userId" in key ? key.userId : "chatId" in key ? key.chatId : key.spaceId
  outboundPublications.enqueue({
    key: `cache:${key.kind}:${id}`,
    run: async () => {
      await internalMessaging.publish({ target: { kind: "cluster" }, event: { kind: "CacheInvalidated", cache } })
    },
    merge: () => {},
  })
}

export function publishAccessChanged(resource: { kind: "chat"; chatId: number } | { kind: "space"; spaceId: number }, affectedUserId?: number): void {
  if (resource.kind === "chat") invalidateLocalCache({ kind: "chatMetadata", chatId: resource.chatId })
  else invalidateLocalCache({ kind: "spaceRecipients", spaceId: resource.spaceId })
  const resourceId = resource.kind === "chat" ? resource.chatId : resource.spaceId
  outboundPublications.enqueue({
    key: `access:${resource.kind}:${resourceId}:${affectedUserId ?? "all"}`,
    run: async () => {
      await internalMessaging.publish({ target: { kind: "cluster" }, event: {
        kind: "AccessChanged",
        resource: resource.kind === "chat" ? { kind: "chat", chatId: ChatId.make(resource.chatId) } : { kind: "space", spaceId: SpaceId.make(resource.spaceId) },
        ...(affectedUserId === undefined ? {} : { affectedUserId: UserId.make(affectedUserId) }),
      } })
    },
    merge: () => {},
  })
}

export function subscribeClusterCaches(): () => void {
  const removeCache = internalMessaging.on("CacheInvalidated", ({ event }) => invalidateLocalCache(event.cache))
  const removeAccess = internalMessaging.on("AccessChanged", async ({ event }) => {
    if (event.resource.kind === "chat") {
      invalidateLocalCache({ kind: "chatMetadata", chatId: event.resource.chatId })
      AccessGuardsCache.resetChatParticipant(event.resource.chatId, event.affectedUserId)
    } else {
      invalidateLocalCache({ kind: "spaceRecipients", spaceId: event.resource.spaceId })
      AccessGuardsCache.resetSpaceMember(event.resource.spaceId, event.affectedUserId)
      const users = event.affectedUserId === undefined
        ? connectionManager.getSpaceUserIds(event.resource.spaceId)
        : [event.affectedUserId]
      await refreshSpaceMemberships(users, event.resource.spaceId)
    }
  })
  const removeContinuity = internalMessaging.onContinuityLost(clearClusterCaches)
  return () => { removeCache(); removeAccess(); removeContinuity() }
}
