/**
 * Presence Manager
 *
 * - we should not leak connection ids here, this should act isolated from the connection manager
 * - we should not store connection ids here
 * - goal for this is to preserve last-seen and update user-reported online status
 * - non goal is to monitor connection status (this is handled by the connection manager)
 * - we should aim to keep this simple and possibly scalable across multiple servers
 */

import { UsersModel } from "@in/server/db/models/users"
import { sendTransientUpdateFor } from "@in/server/modules/updates/sendUpdate"
import { connectionDirectory } from "@in/server/modules/internalMessaging/directory"
import { Log, LogLevel } from "@in/server/utils/log"
import { SessionActivityTracker } from "./sessionActivity"

interface SessionInput {
  userId: number
  sessionId: number
}

type OfflineEvaluation = {
  generation: number
  timer?: ReturnType<typeof setTimeout>
  work?: Promise<void>
  next?: { delayMs: number; retryUnknown: boolean }
}

const MAX_PENDING_OFFLINE_EVALUATIONS = 4_096
const OFFLINE_EVALUATION_DELAY_MS = 10_000
const OFFLINE_RETRY_DELAY_MS = 45_000

export class PresenceManager {
  private readonly log = new Log("presenceManager", LogLevel.WARN)

  private accepting = true
  /** One pending timer or active check per user; entries disappear on completion. */
  private readonly offlineEvaluations = new Map<number, OfflineEvaluation>()
  private shutdownPromise: Promise<void> | undefined
  private stopping = false
  private readonly sessionActivity = new SessionActivityTracker({
    reportError: (error) => this.log.error("Failed to persist session activity", { error }),
  })
  private lifecycleGeneration: number

  constructor() {
    this.lifecycleGeneration = this.sessionActivity.start()
  }

  /** Called by the listener owner after a completed prior shutdown. */
  start(): number {
    if (this.stopping) throw new Error("Presence cannot restart before shutdown completes")
    if (this.accepting) return this.lifecycleGeneration
    const generation = this.sessionActivity.start()
    this.accepting = true
    this.shutdownPromise = undefined
    this.lifecycleGeneration = generation
    return this.lifecycleGeneration
  }

  shutdown(): Promise<void> {
    this.shutdownPromise ??= this.stop(this.lifecycleGeneration)
    return this.shutdownPromise
  }

  private async stop(generation: number): Promise<void> {
    this.stopping = true
    this.accepting = false
    const activeChecks: Promise<void>[] = []
    for (const pending of this.offlineEvaluations.values()) {
      if (pending.timer) clearTimeout(pending.timer)
      pending.timer = undefined
      pending.next = undefined
      if (pending.work) activeChecks.push(pending.work)
    }

    // Stop both producers before joining an already-started directory/DB check.
    await Promise.allSettled([
      this.sessionActivity.shutdown(generation),
      Promise.allSettled(activeChecks).then(() => undefined),
    ])
    this.offlineEvaluations.clear()
    this.stopping = false

    // A process never writes a durable offline flag for sockets owned elsewhere.
  }

  /** Called when a new authenticated connection is made. */
  async handleConnectionOpen(session: SessionInput, generation = this.lifecycleGeneration) {
    if (!this.isCurrentGeneration(generation)) return
    // A reconnect invalidates a timer or completed-directory result from the
    // prior disconnected lifetime before it can write an offline transition.
    this.cancelOfflineEvaluation(session.userId)

    this.sessionActivity.activate(session.sessionId, generation)

    // Do not mark users online automatically. That's controlled by the clients.
  }

  /** Coalesced by SessionActivityTracker; safe to call for every authenticated frame. */
  markSessionActivity(session: SessionInput, generation = this.lifecycleGeneration): void {
    if (!this.isCurrentGeneration(generation)) return
    this.sessionActivity.mark(session.sessionId, generation)
  }

  /** Called when a connection is closed */
  async handleConnectionClose(session: SessionInput, generation = this.lifecycleGeneration, loggedOut = false) {
    if (!this.isCurrentGeneration(generation)) return
    this.log.debug("Connection closed", { userId: session.userId })

    this.sessionActivity.deactivate(session.sessionId, generation)
    if (loggedOut) return
    this.scheduleOfflineEvaluation(session.userId, OFFLINE_EVALUATION_DELAY_MS, true)
  }

  private scheduleOfflineEvaluation(userId: number, delayMs: number, retryUnknown: boolean): void {
    if (!this.accepting) return
    let pending = this.offlineEvaluations.get(userId)
    if (!pending && this.offlineEvaluations.size >= MAX_PENDING_OFFLINE_EVALUATIONS) {
      this.log.warn("Offline evaluation capacity reached", { userId, capacity: MAX_PENDING_OFFLINE_EVALUATIONS })
      return
    }
    if (!pending) {
      pending = { generation: 0 }
      this.offlineEvaluations.set(userId, pending)
    } else {
      if (pending.timer) clearTimeout(pending.timer)
      pending.timer = undefined
      pending.generation += 1
      if (pending.work) {
        // A slow directory call never forms a promise chain: retain one
        // replacement deadline and start it only after this call settles.
        pending.next = { delayMs, retryUnknown }
        return
      }
    }
    this.scheduleOfflineTimer(userId, pending, delayMs, retryUnknown)
  }

  private scheduleOfflineTimer(
    userId: number,
    pending: OfflineEvaluation,
    delayMs: number,
    retryUnknown: boolean,
  ): void {
    const generation = pending.generation
    if (!this.isCurrentOfflineEvaluation(userId, pending, generation)) return
    pending.timer = setTimeout(() => {
      pending.timer = undefined
      this.startOfflineEvaluation(userId, pending, generation, retryUnknown)
    }, delayMs)
    pending.timer.unref?.()
  }

  private startOfflineEvaluation(
    userId: number,
    pending: OfflineEvaluation,
    generation: number,
    retryUnknown: boolean,
  ): void {
    if (!this.isCurrentOfflineEvaluation(userId, pending, generation)) return
    const work = this.evaluateUserOnlineStatus(userId, pending, generation, retryUnknown)
    pending.work = work
    void work.then(
      () => this.finishOfflineEvaluation(userId, pending, work),
      (error) => {
        this.log.error("Failed to evaluate user online status", { userId, error })
        this.finishOfflineEvaluation(userId, pending, work)
      },
    )
  }

  private async evaluateUserOnlineStatus(
    userId: number,
    pending: OfflineEvaluation,
    generation: number,
    retryUnknown: boolean,
  ): Promise<void> {
    const view = await connectionDirectory.list(userId)
    if (!this.isCurrentOfflineEvaluation(userId, pending, generation)) return
    if (view.status === "unavailable" || !view.complete) {
      // An empty rebuilding directory must not turn a live remote socket offline.
      // Retry once after the registration expiry window; sustained loss remains unknown.
      if (retryUnknown) {
        // Keep this entry and its generation so a reconnect can invalidate the
        // retry before it makes any database or transient-update call.
        this.scheduleOfflineTimer(userId, pending, OFFLINE_RETRY_DELAY_MS, false)
      }
      return
    }
    this.log.debug("Evaluating user online status", { userId, connections: view.connections.length })
    if (view.connections.length === 0) {
      this.log.debug("User has no active sessions, marking offline", { userId })
      if (!this.isCurrentOfflineEvaluation(userId, pending, generation)) return
      await this.updateUserOnlineStatus(userId, false)
    }
  }

  private cancelOfflineEvaluation(userId: number): void {
    const pending = this.offlineEvaluations.get(userId)
    if (!pending) return
    if (pending.timer) clearTimeout(pending.timer)
    pending.timer = undefined
    pending.next = undefined
    pending.generation += 1
    if (!pending.work) this.offlineEvaluations.delete(userId)
  }

  private finishOfflineEvaluation(userId: number, pending: OfflineEvaluation, work: Promise<void>): void {
    if (this.offlineEvaluations.get(userId) !== pending || pending.work !== work) return
    pending.work = undefined
    if (pending.next && this.accepting) {
      const next = pending.next
      pending.next = undefined
      this.scheduleOfflineTimer(userId, pending, next.delayMs, next.retryUnknown)
      return
    }
    if (!pending.timer) this.offlineEvaluations.delete(userId)
  }

  private isCurrentOfflineEvaluation(userId: number, pending: OfflineEvaluation, generation: number): boolean {
    return this.accepting && this.offlineEvaluations.get(userId) === pending && pending.generation === generation
  }

  private isCurrentGeneration(generation: number): boolean {
    return this.accepting && this.lifecycleGeneration === generation
  }

  /** Best method for updating user's online status */
  public async updateUserOnlineStatus(userId: number, online: boolean) {
    // Update user's online status
    let { online: newOnline, lastOnline } = await UsersModel.setOnline(userId, online)

    this.log.debug("Updating user online status", { userId, online: newOnline, lastOnline })

    // Send update to all users that have a private dialog with the user
    await sendTransientUpdateFor({
      reason: {
        userPresenceUpdate: { userId, online: newOnline, lastOnline },
      },
    }).catch((error) => {
      this.log.warn("Could not publish transient user presence", { userId, error })
    })
    return { online: newOnline, lastOnline }
  }
}

export const presenceManager = new PresenceManager()
