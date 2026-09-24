import { db } from "@in/server/db"
import { chats } from "@in/server/db/schema"
import { AccessGuards } from "@in/server/modules/authorization/accessGuards"
import { Encoders } from "@in/server/realtime/encoders/encoders"
import { RealtimeUpdates } from "@in/server/realtime/message"
import { connectionManager } from "@in/server/ws/connections"
import { BotPresenceState_Kind, type Update } from "@inline-chat/protocol/core"
import { eq } from "drizzle-orm"
import { getSharedBotPresence } from "./shared"
import { Log } from "@in/server/utils/log"
import { internalMessaging } from "@in/server/modules/internalMessaging/service"

const log = new Log("botPresence.cluster")

/** Retry reads are separately bounded from inbound broker-handler capacity. */
export const maxConcurrentBotPresenceDeliveries = 8
/** One current value/timer is retained for each recipient, bot, and chat. */
export const maxRetainedBotPresenceKeys = 4_096

export type BotPresenceHint = {
  userId: number
  botUserId: number
  chatId: number
}

type DeliveryResult = { retryAfterMs?: number }
type Delivery = (hint: BotPresenceHint, isCurrent: () => boolean) => Promise<DeliveryResult>
type Timer = ReturnType<typeof setTimeout>
type TimerRuntime = {
  set: (callback: () => void, delayMs: number) => Timer
  clear: (timer: Timer) => void
}
type Task = {
  readonly state: State
  readonly promise: Promise<void>
  readonly resolve: () => void
}
type State = {
  readonly key: string
  hint: BotPresenceHint
  generation: number
  timer?: Timer
  queued?: Task
  active?: Promise<void>
  rerun: boolean
}

const systemTimers: TimerRuntime = {
  set(callback, delayMs) {
    const timer = setTimeout(callback, delayMs)
    timer.unref?.()
    return timer
  },
  clear(timer) {
    clearTimeout(timer)
  },
}

/**
 * Owns current-value reads and expiry retries for one broker subscription.
 * A key has one active read, one pending current value, and one timer at most.
 */
export class BotPresenceHintDispatcher {
  private accepting = true
  private readonly states = new Map<string, State>()
  private readonly ready = new Map<string, Task>()
  private readonly active = new Set<Promise<void>>()
  private readonly idleWaiters = new Set<() => void>()
  private dropped = 0

  constructor(
    private readonly deliver: Delivery,
    private readonly timers: TimerRuntime = systemTimers,
  ) {}

  get diagnostics() {
    return {
      accepting: this.accepting,
      active: this.active.size,
      ready: this.ready.size,
      retained: this.states.size,
      dropped: this.dropped,
    }
  }

  observe(hint: BotPresenceHint): Promise<void> {
    if (!this.accepting) return Promise.resolve()
    const key = `${hint.userId}:${hint.botUserId}:${hint.chatId}`
    let state = this.states.get(key)
    if (!state) {
      if (this.states.size >= maxRetainedBotPresenceKeys) {
        this.dropped++
        return Promise.resolve()
      }
      state = { key, hint, generation: 1, rerun: false }
      this.states.set(key, state)
    } else {
      this.clearTimer(state)
      state.hint = hint
      state.generation += 1
    }
    if (state.active) {
      state.rerun = true
      return state.active
    }
    if (state.queued) return state.queued.promise
    return this.queue(state).promise
  }

  async stop(): Promise<void> {
    this.accepting = false
    for (const state of this.states.values()) this.clearTimer(state)
    this.states.clear()
    for (const task of this.ready.values()) task.resolve()
    this.ready.clear()
    this.notifyWhenIdle()
    await this.waitForIdle()
  }

  async waitForIdle(): Promise<void> {
    if (this.active.size === 0 && this.ready.size === 0) return
    await new Promise<void>((resolve) => this.idleWaiters.add(resolve))
  }

  private queue(state: State): Task {
    let resolve!: () => void
    const task: Task = {
      state,
      promise: new Promise<void>((next) => { resolve = next }),
      resolve: () => resolve(),
    }
    state.queued = task
    this.ready.set(state.key, task)
    this.pump()
    return task
  }

  private pump(): void {
    while (this.accepting && this.active.size < maxConcurrentBotPresenceDeliveries && this.ready.size > 0) {
      const next = this.ready.entries().next().value as [string, Task] | undefined
      if (!next) return
      const [key, task] = next
      this.ready.delete(key)
      const state = task.state
      if (!this.isCurrent(state) || state.queued !== task) {
        task.resolve()
        continue
      }
      state.queued = undefined
      let completion!: Promise<void>
      completion = Promise.resolve()
        .then(() => this.run(state))
        .catch((error) => {
          log.warn("Could not resolve shared bot presence", {
            userId: state.hint.userId,
            botUserId: state.hint.botUserId,
            chatId: state.hint.chatId,
            error,
          })
          // A failed current-value read has no safe retry schedule. A newer
          // hint, if one arrived during the failure, is queued below instead.
          if (this.isCurrent(state) && !state.rerun) this.remove(state)
        })
        .then(() => {
          this.active.delete(completion)
          if (state.active === completion) state.active = undefined
          if (this.isCurrent(state) && state.rerun) {
            state.rerun = false
            this.queue(state)
          }
          task.resolve()
          this.pump()
          this.notifyWhenIdle()
        })
      state.active = completion
      this.active.add(completion)
    }
  }

  private async run(state: State): Promise<void> {
    const generation = state.generation
    if (!this.isCurrent(state)) return
    const result = await this.deliver(state.hint, () => this.isCurrent(state) && state.generation === generation)
    if (!this.isCurrent(state) || state.generation !== generation || state.rerun) return
    if (result.retryAfterMs === undefined) {
      this.remove(state)
      return
    }
    this.armRetry(state, generation, result.retryAfterMs)
  }

  private armRetry(state: State, generation: number, retryAfterMs: number): void {
    this.clearTimer(state)
    state.timer = this.timers.set(() => {
      state.timer = undefined
      if (!this.isCurrent(state) || state.generation !== generation || state.active || state.queued) return
      this.queue(state)
    }, Math.max(1, retryAfterMs))
  }

  private clearTimer(state: State): void {
    if (state.timer === undefined) return
    this.timers.clear(state.timer)
    state.timer = undefined
  }

  private remove(state: State): void {
    if (this.states.get(state.key) !== state) return
    this.clearTimer(state)
    this.states.delete(state.key)
  }

  private isCurrent(state: State): boolean {
    return this.accepting && this.states.get(state.key) === state
  }

  private notifyWhenIdle(): void {
    if (this.active.size !== 0 || this.ready.size !== 0) return
    for (const resolve of this.idleWaiters) resolve()
    this.idleWaiters.clear()
  }
}

/** Business handler for typed broker hints. Redis only signals; the current value wins. */
export function subscribeBotPresenceHints(): () => Promise<void> {
  const dispatcher = new BotPresenceHintDispatcher(deliverCurrentPresence)
  const unsubscribe = internalMessaging.on("TransientRealtime", ({ target, event }) => {
    if (event.payload.kind !== "botPresenceChanged") return
    const userId = target.userId
    const { botUserId, chatId } = event.payload
    if (connectionManager.getUserConnections(userId).length === 0) return
    // Returning the owned read keeps aggregate inbound broker work bounded.
    return dispatcher.observe({ userId, botUserId, chatId })
  })
  return async () => {
    unsubscribe()
    await dispatcher.stop()
  }
}

const deliverCurrentPresence: Delivery = async ({ userId, botUserId, chatId }, isCurrent) => {
  const [chat] = await db.select().from(chats).where(eq(chats.id, chatId)).limit(1)
  if (!chat) return {}
  try { await AccessGuards.ensureChatAccess(chat, userId) } catch { return {} }
  const shared = await getSharedBotPresence(botUserId, chatId)
  if (shared.status === "unavailable" || !isCurrent()) return {}
  const update: Update = {
    update: {
      oneofKind: "botPresence",
      botPresence: {
        botUserId: BigInt(botUserId),
        peerId: Encoders.peerFromChat(chat, { currentUserId: userId }),
        state: shared.state,
        avatarChanged: false,
      },
    },
  }
  await RealtimeUpdates.pushToUser(userId, [update])
  if (!isCurrent() || (shared.state.kind === BotPresenceState_Kind.IDLE && !shared.state.comment)) return {}
  return { retryAfterMs: shared.remainingMs + 50 }
}
