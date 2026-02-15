/**
 * Presence Manager
 *
 * - we should not leak connection ids here, this should act isolated from the connection manager
 * - we should not store connection ids here
 * - goal for this is to mark sessions as active or inactive and update user's online status
 * - non goal is to monitor connection status (this is handled by the connection manager)
 * - we should aim to keep this simple and possibly scalable across multiple servers
 */

import { SessionsModel } from "@in/server/db/models/sessions"
import { UsersModel } from "@in/server/db/models/users"
import { sendTransientUpdateFor } from "@in/server/modules/updates/sendUpdate"
import { db } from "@in/server/db"
import { sessions } from "@in/server/db/schema"
import { Log, LogLevel } from "@in/server/utils/log"
import { inArray } from "drizzle-orm"

interface SessionInput {
  userId: number
  sessionId: number
}

class PresenceManager {
  private readonly log = new Log("presenceManager", LogLevel.WARN)

  private readonly sessionActiveTimeout = 1000 * 60 * 10 // 10 minutes
  private readonly sessionHeartbeatInterval = this.sessionActiveTimeout - 1000 * 60 // 9 minutes

  /** Keep track of currently active sessions to update them periodically */
  private readonly currentlyActiveSessions = new Set<number>()

  private readonly evaluateOfflineTimeout = 1000 * 10 // 10 seconds
  private readonly evaluateOfflineTimeoutIds: Map<number, ReturnType<typeof setTimeout>> = new Map() // userId -> timeoutId
  private heartbeatIntervalId: ReturnType<typeof setInterval> | null = null

  constructor() {
    // Keep active sessions active so we won't assume they're stuck inactive
    this.heartbeatIntervalId = setInterval(() => {
      const ids = Array.from(this.currentlyActiveSessions)
      if (ids.length === 0) return

      this.log.trace(`Heartbeating active ${ids.length} sessions`)
      void SessionsModel.setActiveBulk(ids, true).catch((e) => {
        this.log.error("Failed to heartbeat active sessions", { error: e })
      })
    }, this.sessionHeartbeatInterval)
  }

  async shutdown(): Promise<void> {
    if (this.heartbeatIntervalId) {
      clearInterval(this.heartbeatIntervalId)
      this.heartbeatIntervalId = null
    }

    for (const timeoutId of this.evaluateOfflineTimeoutIds.values()) {
      clearTimeout(timeoutId)
    }
    this.evaluateOfflineTimeoutIds.clear()

    const sessionIds = Array.from(this.currentlyActiveSessions)
    this.currentlyActiveSessions.clear()

    if (sessionIds.length === 0) {
      return
    }

    try {
      await SessionsModel.setActiveBulk(sessionIds, false)
    } catch (e) {
      this.log.error("Failed to mark active sessions inactive during shutdown", { error: e, sessionIds })
    }
  }

  /** Called when a new authenticated connection is made. It marks session as active and re-evaluates user's online status */
  async handleConnectionOpen(session: SessionInput) {
    // If we had a pending offline evaluation from a previous disconnect, cancel it.
    clearTimeout(this.evaluateOfflineTimeoutIds.get(session.userId))
    this.evaluateOfflineTimeoutIds.delete(session.userId)

    // Mark session as active
    await SessionsModel.setActive(session.sessionId, true)
    this.currentlyActiveSessions.add(session.sessionId)
    // Do not mark users online automatically. That's controlled by the clients.
  }

  /** Called when a connection is closed */
  async handleConnectionClose(session: SessionInput) {
    try {
      await SessionsModel.setActive(session.sessionId, false)
    } catch (e) {
      this.log.error("Failed to set session active to false", { sessionId: session.sessionId, error: e })
    }

    this.currentlyActiveSessions.delete(session.sessionId)

    this.log.debug("Connection closed", { userId: session.userId })

    // Re-evaluate user's online status to mark them offline if they have no active sessions
    clearTimeout(this.evaluateOfflineTimeoutIds.get(session.userId))
    this.evaluateOfflineTimeoutIds.delete(session.userId)
    this.evaluateOfflineTimeoutIds.set(
      session.userId,
      setTimeout(() => {
        void this.evaluateUserOnlineStatus(session.userId).catch((e) => {
          this.log.error("Failed to evaluate user online status", { userId: session.userId, error: e })
        })
      }, this.evaluateOfflineTimeout),
    )
  }

  /** Updates session's last active timestamp every few minutes to give us a hint that the session is still active so we can make wrong sessions offline later in offline evaluation */
  async sessionHeartbeat(session: SessionInput) {
    try {
      await SessionsModel.setActive(session.sessionId, true)
    } catch (e) {
      this.log.error("Failed to set session active to true", { sessionId: session.sessionId, error: e })
    }
  }

  private async evaluateUserOnlineStatus(userId: number) {
    let activeSessions: Awaited<ReturnType<typeof SessionsModel.getActiveSessionsByUserId>>
    try {
      activeSessions = await SessionsModel.getActiveSessionsByUserId(userId)
    } catch (e) {
      this.log.error("Failed to load active sessions for user", { userId, error: e })
      return
    }

    // Check invalid sessions
    const cutoff = new Date(Date.now() - this.sessionActiveTimeout)
    const recentlyActiveSessions = activeSessions.filter(
      (session) => session.lastActive && session.lastActive >= cutoff,
    )

    const invalidSessionIds = activeSessions
      .filter((session) => !session.lastActive || session.lastActive < cutoff)
      .map((session) => session.id)
    if (invalidSessionIds.length > 0) {
      // These sessions are still marked `active` in the DB, but we haven't seen a heartbeat recently.
      // Mark them inactive without touching `lastActive` (we want lastActive to remain a true "last seen").
      try {
        await db.update(sessions).set({ active: false }).where(inArray(sessions.id, invalidSessionIds))
      } catch (e) {
        this.log.error("Failed to mark invalid sessions inactive", { userId, invalidSessionIds, error: e })
      }

      for (const id of invalidSessionIds) {
        this.currentlyActiveSessions.delete(id)
      }
    }

    this.log.debug("Evaluating user online status", { userId, recentlyActiveSessions: recentlyActiveSessions.length })
    if (recentlyActiveSessions.length === 0) {
      this.log.debug("User has no active sessions, marking offline", { userId })
      try {
        await this.updateUserOnlineStatus(userId, false)
      } catch (e) {
        this.log.error("Failed to mark user offline", { userId, error: e })
      }
    }
  }

  /** Best method for updating user's online status */
  public async updateUserOnlineStatus(userId: number, online: boolean) {
    // Update user's online status
    let { online: newOnline, lastOnline } = await UsersModel.setOnline(userId, online)

    this.log.debug("Updating user online status", { userId, online: newOnline, lastOnline })

    // Send update to all users that have a private dialog with the user
    sendTransientUpdateFor({
      reason: {
        userPresenceUpdate: { userId, online: newOnline, lastOnline },
      },
    })
    return { online: newOnline, lastOnline }
  }
}

export const presenceManager = new PresenceManager()
