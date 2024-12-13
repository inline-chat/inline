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
import { Log } from "@in/server/utils/log"

interface SessionInput {
  userId: number
  sessionId: number
}

class PresenceManager {
  private readonly log = new Log("presenceManager")

  private readonly sessionActiveTimeout = 1000 * 60 * 15 // 15 minutes
  private readonly sessionHeartbeatInterval = this.sessionActiveTimeout - 1000 * 60 // 14 minutes

  /** Keep track of currently active sessions to update them periodically */
  private readonly currentlyActiveSessions = new Set<number>()

  constructor() {
    // Keep active sessions active so we won't assume they're stuck inactive
    setInterval(() => {
      this.log.trace(`Heartbeating active ${this.currentlyActiveSessions.size} sessions`)
      SessionsModel.setActiveBulk(Array.from(this.currentlyActiveSessions), true)
    }, this.sessionHeartbeatInterval)
  }

  /** Called when a new authenticated connection is made. It marks session as active and re-evaluates user's online status */
  async handleConnectionOpen(session: SessionInput) {
    // Mark session as active
    await SessionsModel.setActive(session.sessionId, true)
    this.currentlyActiveSessions.add(session.sessionId)
    // Do not mark users online automatically. That's controlled by the clients.
  }

  /** Called when a connection is closed */
  async handleConnectionClose(session: SessionInput) {
    await SessionsModel.setActive(session.sessionId, false)

    this.currentlyActiveSessions.delete(session.sessionId)

    // Re-evaluate user's online status to mark them offline if they have no active sessions
    await this.evaluateUserOnlineStatus(session.userId)
  }

  /** Updates session's last active timestamp every few minutes to give us a hint that the session is still active so we can make wrong sessions offline later in offline evaluation */
  async sessionHeartbeat(session: SessionInput) {
    await SessionsModel.setActive(session.sessionId, true)
  }

  private async evaluateUserOnlineStatus(userId: number) {
    let sessions = await SessionsModel.getActiveSessionsByUserId(userId)

    // Check invalid sessions
    const recentlyActiveSessions = sessions.filter(
      (session) => session.lastActive && session.lastActive >= new Date(Date.now() - this.sessionActiveTimeout),
    )
    // TODO: Mark invalid sessions as inactive
    this.log.info("Evaluating user online status", { userId, recentlyActiveSessions })
    if (recentlyActiveSessions.length === 0) {
      this.updateUserOnlineStatus(userId, false)
    }
  }

  /** Best method for updating user's online status */
  public async updateUserOnlineStatus(userId: number, online: boolean) {
    // Update user's online status
    let { online: newOnline, lastOnline } = await UsersModel.setOnline(userId, online)

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
