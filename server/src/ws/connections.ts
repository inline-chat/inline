/**
 * Connections Manager
 *
 * - Registers incoming websocket connections and manages users presence via Presence Manager
 */

import { filterFalsy } from "@in/server/utils/filter"
import { Log } from "@in/server/utils/log"
import { presenceManager } from "@in/server/ws/presence"
import { connectionDirectory } from "@in/server/modules/internalMessaging/directory"
import { connectedUserRepair } from "@in/server/modules/internalMessaging/repair"
import { sessionAuthority } from "@in/server/modules/auth/sessionAuthority"
import { connectionBackgroundWork } from "./backgroundWork"
import { WebSocketTopic } from "@in/server/ws/topics"
import type { Server } from "bun"
import type { ElysiaWS } from "elysia/ws"
import invariant from "tiny-invariant"

const log = new Log("ws-connections")

const CLOSE_UNAUTHENTICATED_TIMEOUT = 20_000

export const REALTIME_CLOSE_SESSION_REVOKED = 4401
export const REALTIME_CLOSE_SESSION_REVOKED_REASON = "session_revoked"
export const REALTIME_CLOSE_DURABLE_REPAIR = 4402
export const REALTIME_CLOSE_DURABLE_REPAIR_REASON = "durable_repair"

/** A reconnect fallback is only for a confirmed durable-repair delivery gap. */
export type DurableRepairCloseReason = "no_replayable_record" | "transport_not_accepted"

const DURABLE_REPAIR_CLOSE_MINIMUM_INTERVAL_MS = 30_000
const MAX_DURABLE_REPAIR_CLOSE_GUARDS = 4_096

const pairKey = (firstId: number, secondId: number): string => `${firstId}:${secondId}`

type ConnectionCloseContext = {
  loggedOut?: boolean
  authenticationInvalidated?: boolean
  durableRepair?: DurableRepairCloseReason
}

export type SessionClientTypeHydrator = (
  input: { userId: number; sessionId: number },
) => Promise<string | undefined>

export type SpaceMembershipHydrator = (
  input: { userId: number; spaceId: number },
) => Promise<boolean>

const loadSessionClientType: SessionClientTypeHydrator = async ({
  userId,
  sessionId,
}) => {
  const [{ db }, { sessions }, orm] = await Promise.all([
    import("@in/server/db"),
    import("@in/server/db/schema"),
    import("drizzle-orm"),
  ])
  const rows = await db
    .select({ clientType: sessions.clientType })
    .from(sessions)
    .where(orm.and(
      orm.eq(sessions.id, sessionId),
      orm.eq(sessions.userId, userId),
      orm.isNull(sessions.revoked),
    ))
    .limit(1)
  return rows[0]?.clientType ?? undefined
}

const loadCurrentSpaceMembership: SpaceMembershipHydrator = async ({ userId, spaceId }) => {
  const { getCurrentSpaceMembership } = await import("@in/server/modules/authorization/spaceMembershipLifecycle")
  return Boolean(await getCurrentSpaceMembership(spaceId, userId))
}

export enum ConnVersion {
  BASIC_V1 = 1,
  REALTIME_V1 = 2,
  REALTIME_V3 = 3,
}

type WS = ElysiaWS<any, any>

interface Connection {
  connectionId: string
  ws: WS

  version: ConnVersion

  /** Close unauthenticated connections after a grace period. Cleared on auth or close. */
  unauthenticatedCloseTimeoutId?: ReturnType<typeof setTimeout>

  // For authenticated connections
  userId?: number
  sessionId?: number
  isBot?: boolean
  clientType?: string
  presenceGeneration?: number

  /** Realtime API layer */
  layer?: number
}

type AuthenticatedSessionConnections = {
  userId: number
  sessionId: number
  connectionIds: Set<string>
}

type MembershipRefresh = {
  /** Latest invalidation only; arrivals during a read require one successor. */
  pending?: { load: SpaceMembershipHydrator; lifetime: Set<string> }
  /** Local projections fence only this user/space read, not other spaces. */
  revision: number
  promise: Promise<void>
}

class ConnectionManager {
  private server: Server<unknown> | undefined
  private connections: Map<string, Connection> = new Map()
  private authenticatedUsers: Map<number, Set<string>> = new Map()
  /** Narrows session-scoped operations without scanning every live socket. */
  private authenticatedSessions = new Map<string, AuthenticatedSessionConnections>()
  private usersBySpaceId: Map<number, Set<number>> = new Map()
  private userSpaceIds: Map<number, number[]> = new Map()
  private userSpaceMembershipRevision: Map<number, number> = new Map()
  /** Changes on every authenticated socket membership change; prevents stale repair work from closing a fresh reconnect. */
  private userConnectionEpochs: Map<number, number> = new Map()
  private nextUserConnectionEpoch = 0
  /** Rate guard for protocol-compatible reconnect repair, bounded to prevent untrusted user-id churn from retaining memory. */
  private durableRepairCloseGuards: Map<number, number> = new Map()
  /** One live lookup per session; removed when its client type resolves or fails. */
  private readonly clientTypeHydrations = new Map<string, Promise<void>>()
  /** One owned read and at most one pending invalidation per user/space. */
  private readonly membershipRefreshes = new Map<string, MembershipRefresh>()
  /** Listener-owned generation rejects late presence callbacks after a restart. */
  private presenceGeneration: number | undefined

  setServer(server: Server<unknown>) {
    this.server = server
    this.presenceGeneration = presenceManager.start?.() ?? this.presenceGeneration
  }

  getConnection(id: string): Connection | undefined {
    return this.connections.get(id)
  }

  getTotalConnections(): number {
    return this.connections.size
  }

  getAuthenticatedConnectionCount(): number {
    let count = 0
    for (const connection of this.connections.values()) {
      if (connection.userId) {
        count += 1
      }
    }
    return count
  }

  getAuthenticatedUserCount(): number {
    return this.authenticatedUsers.size
  }

  getAuthenticatedUserIds(): number[] { return [...this.authenticatedUsers.keys()] }

  getUserConnectionSummary(userId: number): { totalConnections: number; sessions: { sessionId: number; count: number }[] } {
    const userConnections = this.authenticatedUsers.get(userId) ?? new Set<string>()
    const sessionCounts = new Map<number, number>()

    for (const connectionId of userConnections) {
      const connection = this.connections.get(connectionId)
      if (!connection?.sessionId) continue
      sessionCounts.set(connection.sessionId, (sessionCounts.get(connection.sessionId) ?? 0) + 1)
    }

    const sessions = Array.from(sessionCounts.entries()).map(([sessionId, count]) => ({ sessionId, count }))
    return { totalConnections: userConnections.size, sessions }
  }

  getConnectionIdFromWs(ws: WS): string {
    let id = ws.id
    invariant(id, "ID is not available on WS")
    return id
  }

  addConnection(ws: WS, version: ConnVersion): string {
    log.debug("Adding new connection")
    //const id = nanoid()
    const id = this.getConnectionIdFromWs(ws)
    const connection: Connection = { connectionId: id, ws, version }
    this.connections.set(id, connection)

    // Start timeout, if not authenticated in 20 seconds, close the connection
    connection.unauthenticatedCloseTimeoutId = setTimeout(() => {
      const connection = this.connections.get(id)
      if (connection && !connection.userId) {
        log.debug(`Connection ${id} not authenticated, closing`)
        this.closeConnection(id)
      }
    }, CLOSE_UNAUTHENTICATED_TIMEOUT)

    return id
  }

  authenticateConnection(id: string, userId: number, sessionId: number, layer: number = 1, isBot: boolean = false, clientType: string = "unknown"): boolean {
    log.debug(`Authenticating connection ${id} for user ${userId}`)
    const connection = this.connections.get(id)
    if (!connection) return false
    // A socket's identity is immutable after admission. Re-admitting the same
    // identity is harmless; accepting a different one would leave stale
    // session and presence ownership behind.
    if (connection.userId !== undefined &&
      (connection.userId !== userId || connection.sessionId !== sessionId)) {
      log.warn("Rejected websocket identity change after authentication", {
        connectionId: id,
        previousUserId: connection.userId,
        previousSessionId: connection.sessionId,
        userId,
        sessionId,
      })
      this.closeConnection(id, { authenticationInvalidated: true })
      return false
    }
    // Connection init already queried the session row. This synchronous gate
    // prevents a revocation event that arrived just before registration from
    // being lost between that query and the local connection map update.
    if (!sessionAuthority.admit({ userId, sessionId })) {
      this.closeConnection(id, { authenticationInvalidated: true })
      return false
    }

    clearTimeout(connection.unauthenticatedCloseTimeoutId)
    connection.unauthenticatedCloseTimeoutId = undefined

    connection.userId = userId
    connection.sessionId = sessionId
    connection.isBot = isBot
    connection.clientType = clientType
    connection.layer = layer
    connection.presenceGeneration = this.presenceGeneration ?? presenceManager.start?.()
    connectionDirectory.register({ connectionId: id, userId, sessionId, clientType, isBot })

    void presenceManager.handleConnectionOpen({ userId, sessionId }, connection.presenceGeneration).catch((e) => {
      log.error("presenceManager.handleConnectionOpen failed", { userId, sessionId, error: e })
    })

    if (!this.authenticatedUsers.has(userId)) {
      // User is connecting for the first time, populate the cache
      this.authenticatedUsers.set(userId, new Set())
      this.startMembershipHydration(userId)
    }
    this.authenticatedUsers.get(userId)?.add(id)
    this.addAuthenticatedSessionConnection(id, userId, sessionId)
    this.bumpUserConnectionEpoch(userId)
    const repairTimer = setTimeout(() => {
      if (this.connections.get(id)?.userId === userId) connectedUserRepair.observeConnection(userId)
    }, 0)
    repairTimer.unref?.()
    return true
  }

  updateAuthenticatedClientType(id: string, userId: number, sessionId: number, clientType: string): void {
    const connection = this.connections.get(id)
    if (connection?.userId !== userId || connection.sessionId !== sessionId) return
    connection.clientType = clientType
    connectionDirectory.register({ connectionId: id, userId, sessionId, clientType, isBot: connection.isBot ?? false })
  }

  /** Marks activity locally; persistence is batched by PresenceManager. */
  markConnectionActivity(id: string): void {
    const connection = this.connections.get(id)
    if (connection?.userId === undefined || connection.sessionId === undefined) return
    presenceManager.markSessionActivity?.(
      { userId: connection.userId, sessionId: connection.sessionId },
      connection.presenceGeneration,
    )
  }

  /**
   * Hydrate the client type only when V3 authentication did not carry it.
   * Concurrent sockets for one session share the lookup; a known sibling makes
   * this a purely local update. The promise is tracked for teardown because
   * the database read intentionally outlives the authorization callback.
   */
  hydrateAuthenticatedClientType(
    userId: number,
    sessionId: number,
    load: SessionClientTypeHydrator = loadSessionClientType,
  ): void {
    const known = this.getKnownSessionClientType(userId, sessionId)
    if (known !== undefined) {
      this.updateSessionClientType(userId, sessionId, known)
      return
    }

    const key = pairKey(userId, sessionId)
    if (this.clientTypeHydrations.has(key)) return

    const hydration = Promise.resolve()
      .then(() => load({ userId, sessionId }))
      .then((clientType) => {
        if (clientType !== undefined) {
          this.updateSessionClientType(userId, sessionId, clientType)
        }
      })
      .catch((error) => {
        log.warn("Failed to hydrate authenticated client type", {
          userId,
          sessionId,
          error,
        })
      })

    this.clientTypeHydrations.set(key, hydration)
    connectionBackgroundWork.track(hydration)
    void hydration.finally(() => {
      if (this.clientTypeHydrations.get(key) === hydration) {
        this.clientTypeHydrations.delete(key)
      }
    })
  }

  closeConnection(id: string, context: ConnectionCloseContext = {}) {
    log.debug(`Closing connection ${id}`)
    const connection = this.connections.get(id)
    if (connection) {
      try {
        if (context.authenticationInvalidated) {
          connection.ws.close(REALTIME_CLOSE_SESSION_REVOKED, REALTIME_CLOSE_SESSION_REVOKED_REASON)
        } else if (context.durableRepair) {
          connection.ws.close(REALTIME_CLOSE_DURABLE_REPAIR, REALTIME_CLOSE_DURABLE_REPAIR_REASON)
        } else {
          connection.ws.close()
        }
      } catch (error) {
        log.error(error)
      }
      this.removeConnection(id, context)
    }
  }

  sessionLoggedOut(userId: number, sessionId: number, exceptConnectionId?: string) {
    this.closeConnectionForSession(userId, sessionId, { loggedOut: true }, exceptConnectionId)
  }

  closeConnectionForSession(
    userId: number,
    sessionId: number,
    context: ConnectionCloseContext = {},
    exceptConnectionId?: string,
  ) {
    const connectionIds = this.getSessionConnectionIds(userId, sessionId)
    if (connectionIds.length === 0) return

    for (const id of connectionIds) {
      if (id === exceptConnectionId) continue
      this.closeConnection(id, context)
    }
  }

  /**
   * Reconnect fallback for a completed repair scan only. It is intentionally
   * distinct from revocation: callers may use it only after a durable record
   * exists but no current socket accepted the replay (or no compatible record
   * can carry that frontier). `expectedConnectionEpoch` prevents an old scan
   * from disconnecting sockets that reconnected while it was awaiting data.
   */
  closeUserConnectionsForDurableRepair(
    userId: number,
    reason: DurableRepairCloseReason,
    expectedConnectionEpoch?: number,
  ): number {
    const currentEpoch = this.getUserConnectionEpoch(userId)
    if (expectedConnectionEpoch !== undefined && expectedConnectionEpoch !== currentEpoch) return 0
    const connectionIds = [...(this.authenticatedUsers.get(userId) ?? [])]
    if (connectionIds.length === 0) return 0

    const now = performance.now()
    this.pruneDurableRepairCloseGuards(now)
    if (this.durableRepairCloseGuards.has(userId)) return 0
    this.durableRepairCloseGuards.set(userId, now)
    this.trimDurableRepairCloseGuards()
    log.warn("Closing user connections for durable repair", { userId, reason, connectionEpoch: currentEpoch })

    let closed = 0
    for (const id of connectionIds) {
      if (!this.connections.has(id)) continue
      this.closeConnection(id, { durableRepair: reason })
      closed += 1
    }
    return closed
  }

  removeConnection(id: string, context: ConnectionCloseContext = {}) {
    log.debug(`Removing connection ${id}`)
    const connection = this.connections.get(id)
    if (connection) {
      clearTimeout(connection.unauthenticatedCloseTimeoutId)
      connection.unauthenticatedCloseTimeoutId = undefined

      this.connections.delete(id)
      connectionDirectory.unregister(id)
      if (connection.userId && connection.sessionId) {
        this.bumpUserConnectionEpoch(connection.userId)
        const userConnections = this.authenticatedUsers.get(connection.userId)
        userConnections?.delete(id)
        const hasOtherConnectionsForSession = this.removeAuthenticatedSessionConnection(
          id,
          connection.userId,
          connection.sessionId,
          userConnections,
        )

        // Schedule offline evaluation only after the last local socket closes.
        // A logged-out socket does not schedule presence work.
        if (!hasOtherConnectionsForSession) {
          void presenceManager.handleConnectionClose(
            { userId: connection.userId, sessionId: connection.sessionId },
            connection.presenceGeneration,
            context.loggedOut === true,
          ).catch((e) => {
            log.error("presenceManager.handleConnectionClose failed", {
              userId: connection.userId,
              sessionId: connection.sessionId,
              error: e,
            })
          })
        }
        if (!hasOtherConnectionsForSession) {
          sessionAuthority.forget({ userId: connection.userId, sessionId: connection.sessionId })
        }

        if (userConnections && userConnections.size === 0) {
          for (const spaceId of this.userSpaceIds.get(connection.userId) ?? []) {
            this.unsubscribeUserFromSpace(connection.userId, spaceId)
          }
          this.authenticatedUsers.delete(connection.userId)
          this.userSpaceIds.delete(connection.userId)
          this.userSpaceMembershipRevision.delete(connection.userId)
          this.userConnectionEpochs.delete(connection.userId)
        }
      }
    }
  }

  async shutdown(): Promise<void> {
    // Stop the session-activity producer before draining connection or
    // application work. Its shutdown joins one bounded lastActive write.
    await presenceManager.shutdown?.()
    this.presenceGeneration = undefined
    const totalConnections = this.connections.size
    if (totalConnections === 0) {
      this.authenticatedUsers.clear()
      this.authenticatedSessions.clear()
      this.usersBySpaceId.clear()
      this.userSpaceIds.clear()
      this.userSpaceMembershipRevision.clear()
      this.userConnectionEpochs.clear()
      this.durableRepairCloseGuards.clear()
      this.clientTypeHydrations.clear()
      this.membershipRefreshes.clear()
      await this.waitForBackgroundWork()
      return
    }

    log.info("Shutting down websocket connections", { totalConnections })

    for (const connection of this.connections.values()) {
      connectionDirectory.unregister(connection.connectionId)
      clearTimeout(connection.unauthenticatedCloseTimeoutId)
      connection.unauthenticatedCloseTimeoutId = undefined

      try {
        connection.ws.close()
      } catch (error) {
        log.error("Failed to close websocket during shutdown", { error })
      }
    }

    this.connections.clear()
    this.authenticatedUsers.clear()
    this.authenticatedSessions.clear()
    this.usersBySpaceId.clear()
    this.userSpaceIds.clear()
    this.userSpaceMembershipRevision.clear()
    this.userConnectionEpochs.clear()
    this.durableRepairCloseGuards.clear()
    this.clientTypeHydrations.clear()
    this.membershipRefreshes.clear()
    await this.waitForBackgroundWork()
  }

  /**
   * Wait for work started during connection admission that can still hold a
   * database read lock. This is for controlled shutdown and test teardown;
   * individual request paths stay asynchronous.
   */
  async waitForBackgroundWork(): Promise<void> {
    await connectionBackgroundWork.waitForIdle()
  }

  getUserConnections(userId: number): Connection[] {
    const userConnections = this.authenticatedUsers.get(userId) ?? new Set<string>()
    return [...userConnections].map((conId) => this.connections.get(conId)).filter(filterFalsy)
  }

  /** Snapshot immediately before asynchronous durable repair work begins. */
  getUserConnectionEpoch(userId: number): number {
    return this.userConnectionEpochs.get(userId) ?? 0
  }

  getAuthenticatedSessionIdentities(): { userId: number; sessionId: number }[] {
    return [...this.authenticatedSessions.values()].map(({ userId, sessionId }) => ({ userId, sessionId }))
  }

  getConnectionBySession(userId: number, sessionId: number): Connection | undefined {
    for (const connectionId of this.getSessionConnectionIds(userId, sessionId)) {
      const connection = this.connections.get(connectionId)
      if (connection) return connection
    }

    return undefined
  }

  getSpaceUserIds(spaceId: number): number[] {
    return Array.from(this.usersBySpaceId.get(spaceId) ?? [])
  }

  subscribeToSpace(userId: number, spaceId: number): void {
    log.debug(`Subscribing to space ${spaceId} for user ${userId}`)

    // Cache the user in the space
    let spaceConnections = this.usersBySpaceId.get(spaceId)
    if (!spaceConnections) {
      spaceConnections = new Set()
      this.usersBySpaceId.set(spaceId, spaceConnections)
    }
    spaceConnections.add(userId)
    const cachedSpaceIds = this.userSpaceIds.get(userId) ?? []
    if (!cachedSpaceIds.includes(spaceId)) {
      this.userSpaceIds.set(userId, [...cachedSpaceIds, spaceId])
    }

    // Subscribe the user to the space
    const userConnections = this.authenticatedUsers.get(userId)
    if (userConnections) {
      userConnections.forEach((connectionId) => {
        const connection = this.connections.get(connectionId)
        if (connection?.version === ConnVersion.BASIC_V1) {
          connection?.ws.subscribe(WebSocketTopic.Space(spaceId))
        }
      })
    }
  }

  /**
   * Projects DB-locked membership into active process-local fanout. Offline
   * accounts hydrate from the DB when they connect; do not retain every add.
   */
  activateSpaceMembership(userId: number, spaceId: number): void {
    if (!this.authenticatedUsers.has(userId)) return
    this.invalidateMembershipRefresh(userId, spaceId)
    this.userSpaceMembershipRevision.set(userId, (this.userSpaceMembershipRevision.get(userId) ?? 0) + 1)
    this.subscribeToSpace(userId, spaceId)
  }

  refreshSpaceMembership(
    userId: number,
    spaceId: number,
    load: SpaceMembershipHydrator = loadCurrentSpaceMembership,
  ): Promise<void> {
    const lifetime = this.authenticatedUsers.get(userId)
    if (!lifetime) return Promise.resolve()
    const key = pairKey(userId, spaceId)
    const existing = this.membershipRefreshes.get(key)
    if (existing) {
      existing.pending = { load, lifetime }
      return existing.promise
    }
    const refresh: MembershipRefresh = {
      pending: { load, lifetime },
      revision: 0,
      // Defer the first read until its owner is registered. Invalidations in
      // this same turn coalesce without starting an unnecessary stale query.
      promise: Promise.resolve().then(() => this.doRefreshSpaceMembership(userId, spaceId, key, refresh)),
    }
    this.membershipRefreshes.set(key, refresh)
    connectionBackgroundWork.track(refresh.promise)
    return refresh.promise
  }

  private async doRefreshSpaceMembership(
    userId: number,
    spaceId: number,
    key: string,
    refresh: MembershipRefresh,
  ): Promise<void> {
    try {
      while (refresh.pending && this.membershipRefreshes.get(key) === refresh) {
        const request = refresh.pending
        refresh.pending = undefined
        if (this.authenticatedUsers.get(userId) !== request.lifetime) continue
        const revision = refresh.revision
        const isCurrent = () => this.membershipRefreshes.get(key) === refresh &&
          this.authenticatedUsers.get(userId) === request.lifetime &&
          refresh.revision === revision && refresh.pending === undefined
        let member: boolean
        try {
          member = await request.load({ userId, spaceId })
        } catch (error) {
          // An obsolete failure must not swallow an already-admitted successor.
          if (!isCurrent()) continue
          throw error
        }
        if (!isCurrent()) continue
        if (member) this.activateSpaceMembership(userId, spaceId)
        else this.unsubscribeUserFromSpace(userId, spaceId)
      }
    } finally {
      // Remove admission synchronously with the final loop check. A later
      // promise-finally callback would leave a gap that could lose a new event.
      if (this.membershipRefreshes.get(key) === refresh) this.membershipRefreshes.delete(key)
    }
  }

  /** Immediately removes a former member from process-local Space fanout. */
  unsubscribeUserFromSpace(userId: number, spaceId: number): void {
    log.debug(`Unsubscribing from space ${spaceId} for user ${userId}`)
    this.invalidateMembershipRefresh(userId, spaceId)
    if (this.authenticatedUsers.has(userId)) {
      this.userSpaceMembershipRevision.set(userId, (this.userSpaceMembershipRevision.get(userId) ?? 0) + 1)
    }

    const spaceUsers = this.usersBySpaceId.get(spaceId)
    spaceUsers?.delete(userId)
    if (spaceUsers?.size === 0) this.usersBySpaceId.delete(spaceId)

    const cachedSpaceIds = this.userSpaceIds.get(userId)
    if (cachedSpaceIds) this.userSpaceIds.set(userId, cachedSpaceIds.filter((id) => id !== spaceId))

    for (const connectionId of this.authenticatedUsers.get(userId) ?? []) {
      const connection = this.connections.get(connectionId)
      if (connection?.version === ConnVersion.BASIC_V1) {
        connection.ws.unsubscribe(WebSocketTopic.Space(spaceId))
      }
    }
  }

  // ------------------------------------------------------------------------------------------------
  // Private methods
  // ------------------------------------------------------------------------------------------------

  private async getUserSpaceIds(userId: number): Promise<number[]> {
    // Lazy import so this module doesn't eagerly load db/env at startup.
    const { getSpaceIdsForUser } = await import("@in/server/db/models/spaces")
    return await getSpaceIdsForUser(userId)
  }

  private bumpUserConnectionEpoch(userId: number): void {
    this.nextUserConnectionEpoch += 1
    this.userConnectionEpochs.set(userId, this.nextUserConnectionEpoch)
  }

  private getKnownSessionClientType(userId: number, sessionId: number): string | undefined {
    for (const connectionId of this.getSessionConnectionIds(userId, sessionId)) {
      const connection = this.connections.get(connectionId)
      if (connection?.clientType !== undefined && connection.clientType !== "unknown") {
        return connection.clientType
      }
    }
    return undefined
  }

  private updateSessionClientType(userId: number, sessionId: number, clientType: string): void {
    for (const connectionId of this.getSessionConnectionIds(userId, sessionId)) {
      this.updateAuthenticatedClientType(connectionId, userId, sessionId, clientType)
    }
  }

  private addAuthenticatedSessionConnection(connectionId: string, userId: number, sessionId: number): void {
    const key = pairKey(userId, sessionId)
    let session = this.authenticatedSessions.get(key)
    if (!session) {
      session = { userId, sessionId, connectionIds: new Set() }
      this.authenticatedSessions.set(key, session)
    }
    session.connectionIds.add(connectionId)
  }

  private removeAuthenticatedSessionConnection(
    connectionId: string,
    userId: number,
    sessionId: number,
    userConnections: Set<string> | undefined,
  ): boolean {
    const key = pairKey(userId, sessionId)
    const session = this.authenticatedSessions.get(key)
    if (session) {
      session.connectionIds.delete(connectionId)
      if (session.connectionIds.size === 0) this.authenticatedSessions.delete(key)
      return session.connectionIds.size > 0
    }

    // Defensive fallback for legacy callers/tests that populated connection
    // fields directly instead of going through authenticateConnection.
    for (const otherId of userConnections ?? []) {
      if (this.connections.get(otherId)?.sessionId === sessionId) return true
    }
    if (!userConnections) {
      for (const other of this.connections.values()) {
        if (other.userId === userId && other.sessionId === sessionId) return true
      }
    }
    return false
  }

  private getSessionConnectionIds(userId: number, sessionId: number): string[] {
    const indexed = this.authenticatedSessions.get(pairKey(userId, sessionId))
    if (indexed) return [...indexed.connectionIds]

    const fallback: string[] = []
    for (const connectionId of this.authenticatedUsers.get(userId) ?? []) {
      if (this.connections.get(connectionId)?.sessionId === sessionId) fallback.push(connectionId)
    }
    return fallback
  }

  private invalidateMembershipRefresh(userId: number, spaceId: number): void {
    const refresh = this.membershipRefreshes.get(pairKey(userId, spaceId))
    if (refresh) refresh.revision += 1
  }

  private pruneDurableRepairCloseGuards(now: number): void {
    for (const [userId, closedAt] of this.durableRepairCloseGuards) {
      if (now - closedAt >= DURABLE_REPAIR_CLOSE_MINIMUM_INTERVAL_MS) {
        this.durableRepairCloseGuards.delete(userId)
      }
    }
  }

  private trimDurableRepairCloseGuards(): void {
    while (this.durableRepairCloseGuards.size > MAX_DURABLE_REPAIR_CLOSE_GUARDS) {
      const oldestUserId = this.durableRepairCloseGuards.keys().next().value
      if (oldestUserId === undefined) return
      this.durableRepairCloseGuards.delete(oldestUserId)
    }
  }

  private async subscribeUserToSpaceIds(userId: number): Promise<void> {
    const userConnections = this.authenticatedUsers.get(userId)
    if (!userConnections) return
    // A membership removal can race the initial database read. Retry from the
    // authoritative database whenever the revision changes so stale results
    // cannot resubscribe a removed user after unsubscribeUserFromSpace.
    while (true) {
      const revision = this.userSpaceMembershipRevision.get(userId) ?? 0
      const spaceIds = await this.getUserSpaceIds(userId)
      // The Set is the existing authenticated lifetime identity. A disconnect
      // followed by reconnect must not let the old in-flight read repopulate it.
      if (this.authenticatedUsers.get(userId) !== userConnections) return
      if ((this.userSpaceMembershipRevision.get(userId) ?? 0) !== revision) continue

      this.userSpaceIds.set(userId, spaceIds)
      spaceIds.forEach((spaceId) => this.subscribeToSpace(userId, spaceId))
      return
    }
  }

  private startMembershipHydration(userId: number): void {
    const hydration = this.subscribeUserToSpaceIds(userId).catch((error) => {
      log.error("Failed to subscribe user to spaces", { userId, error })
    })
    connectionBackgroundWork.track(hydration)
  }
}

export const connectionManager = new ConnectionManager()
