/**
 * An in-memory browser for link tests: Web Locks, broadcast channels, a
 * virtual clock and page lifecycle, shared by several fake tabs.
 *
 * Asynchrony is explicit: lock grants and channel deliveries are tasks in the
 * world's queue, run by `settle()` in order. Channel messages go through
 * `structuredClone`, so a message that would not cross a real channel fails.
 */

import type {
  ChannelLike,
  Clock,
  HeldLock,
  LifecycleEvent,
  LifecycleSource,
  LockManagerLike,
  PortMessageListener,
  TimerHandle,
} from "../platform"

export class VirtualClock implements Clock {
  private time: number
  private nextId = 1
  private readonly timers = new Map<number, { at: number; callback: () => void }>()

  constructor(start = 1_000_000) {
    this.time = start
  }

  now() {
    return this.time
  }

  setTimeout(callback: () => void, ms: number): TimerHandle {
    const id = this.nextId++
    this.timers.set(id, { at: this.time + Math.max(0, ms), callback })
    return id
  }

  clearTimeout(handle: TimerHandle) {
    this.timers.delete(handle as number)
  }

  get pendingTimers() {
    return this.timers.size
  }

  /** Moves time forward without running timers, as when the machine sleeps. The next `advance` runs them late. */
  jump(ms: number) {
    this.time += ms
  }

  /** Moves time forward, running due timers in order. */
  advance(ms: number) {
    const end = this.time + ms
    for (;;) {
      let next: [number, { at: number; callback: () => void }] | undefined
      for (const entry of this.timers) {
        if (entry[1].at <= end && (!next || entry[1].at < next[1].at)) next = entry
      }
      if (!next) break
      this.timers.delete(next[0])
      this.time = Math.max(this.time, next[1].at)
      next[1].callback()
    }
    this.time = end
  }
}

const abortError = () => Object.assign(new Error("The request was aborted."), { name: "AbortError" })

type LockRequest = {
  client: string
  resolve: (lock: HeldLock) => void
  reject: (error: Error) => void
}

class FakeLockRegistry {
  private readonly held = new Map<string, { client: string; token: object }>()
  private readonly queues = new Map<string, LockRequest[]>()

  constructor(private readonly schedule: (task: () => void) => void) {}

  acquire(client: string, name: string, signal?: AbortSignal): Promise<HeldLock> {
    return new Promise<HeldLock>((resolve, reject) => {
      if (signal?.aborted) {
        reject(abortError())
        return
      }
      const request: LockRequest = { client, resolve, reject }
      const queue = this.queues.get(name) ?? []
      queue.push(request)
      this.queues.set(name, queue)
      signal?.addEventListener("abort", () => {
        const current = this.queues.get(name)
        const index = current?.indexOf(request) ?? -1
        if (current && index >= 0) {
          current.splice(index, 1)
          reject(abortError())
        }
      })
      this.schedule(() => this.pump(name))
    })
  }

  tryAcquire(client: string, name: string): Promise<HeldLock | null> {
    return new Promise((resolve) => {
      this.schedule(() => {
        if (this.held.has(name) || (this.queues.get(name)?.length ?? 0) > 0) {
          resolve(null)
          return
        }
        resolve(this.grant(name, client))
      })
    })
  }

  kill(client: string) {
    for (const [name, queue] of this.queues) {
      this.queues.set(name, queue.filter((request) => request.client !== client))
    }
    for (const [name, holder] of Array.from(this.held)) {
      if (holder.client !== client) continue
      this.held.delete(name)
      this.schedule(() => this.pump(name))
    }
  }

  heldNames(): string[] {
    return [...this.held.keys()]
  }

  holder(name: string): string | undefined {
    return this.held.get(name)?.client
  }

  queuedCount(): number {
    let count = 0
    for (const queue of this.queues.values()) count += queue.length
    return count
  }

  private pump(name: string) {
    if (this.held.has(name)) return
    const request = this.queues.get(name)?.shift()
    if (!request) return
    request.resolve(this.grant(name, request.client))
  }

  private grant(name: string, client: string): HeldLock {
    const token = {}
    this.held.set(name, { client, token })
    return {
      release: () => {
        if (this.held.get(name)?.token !== token) return
        this.held.delete(name)
        this.schedule(() => this.pump(name))
      },
    }
  }
}

class FakeChannel implements ChannelLike {
  private readonly listeners = new Set<PortMessageListener>()
  open = true

  constructor(
    private readonly world: FakeWorld,
    readonly name: string,
    readonly client: string,
  ) {}

  postMessage(message: unknown) {
    if (!this.open) throw new Error("InvalidStateError: channel is closed")
    const data = structuredClone(message)
    for (const peer of this.world.channelsNamed(this.name)) {
      if (peer === this) continue
      this.world.schedule(() => peer.dispatch(structuredClone(data)))
    }
  }

  addEventListener(_type: "message", listener: PortMessageListener) {
    this.listeners.add(listener)
  }

  removeEventListener(_type: "message", listener: PortMessageListener) {
    this.listeners.delete(listener)
  }

  close() {
    if (!this.open) return
    this.open = false
    this.world.removeChannel(this)
  }

  dispatch(data: unknown) {
    if (!this.open) return
    for (const listener of Array.from(this.listeners)) listener({ data })
  }
}

export class FakeLifecycle implements LifecycleSource {
  private readonly listeners = new Set<(event: LifecycleEvent) => void>()

  subscribe(listener: (event: LifecycleEvent) => void) {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  fire(event: LifecycleEvent) {
    for (const listener of Array.from(this.listeners)) listener(event)
  }

  get listenerCount() {
    return this.listeners.size
  }
}

export type FakeTab = {
  id: string
  locks: LockManagerLike
  channels: (name: string) => ChannelLike
  clock: VirtualClock
  lifecycle: FakeLifecycle
  /** Runs when the tab is killed; a test core registers its own death here. */
  onKill(callback: () => void): void
  /** The tab is gone: its locks free, its channels close, its cores die. No code of it runs again. */
  kill(): void
  readonly alive: boolean
}

export class FakeWorld {
  readonly clock = new VirtualClock()
  private readonly tasks: (() => void)[] = []
  private readonly channels = new Set<FakeChannel>()
  private readonly lockRegistry = new FakeLockRegistry((task) => this.schedule(task))

  schedule(task: () => void) {
    this.tasks.push(task)
  }

  channelsNamed(name: string): FakeChannel[] {
    return [...this.channels].filter((channel) => channel.name === name)
  }

  removeChannel(channel: FakeChannel) {
    this.channels.delete(channel)
  }

  openChannels(): string[] {
    return [...this.channels].map((channel) => `${channel.client}:${channel.name}`)
  }

  heldLocks(): string[] {
    return this.lockRegistry.heldNames()
  }

  lockHolder(name: string): string | undefined {
    return this.lockRegistry.holder(name)
  }

  queuedLockRequests(): number {
    return this.lockRegistry.queuedCount()
  }

  tab(id: string): FakeTab {
    const killCallbacks: (() => void)[] = []
    let alive = true
    const tabChannels = new Set<FakeChannel>()
    const registry = this.lockRegistry
    const tab: FakeTab = {
      id,
      locks: {
        acquire: (name, signal) => registry.acquire(id, name, signal),
        tryAcquire: (name) => registry.tryAcquire(id, name),
      },
      channels: (name) => {
        const channel = new FakeChannel(this, name, id)
        this.channels.add(channel)
        tabChannels.add(channel)
        return channel
      },
      clock: this.clock,
      lifecycle: new FakeLifecycle(),
      onKill: (callback) => {
        killCallbacks.push(callback)
      },
      kill: () => {
        if (!alive) return
        alive = false
        for (const channel of tabChannels) channel.close()
        registry.kill(id)
        for (const callback of killCallbacks) callback()
      },
      get alive() {
        return alive
      },
    }
    return tab
  }

  /** Runs queued tasks and microtasks until nothing is left. */
  async settle(maxTasks = 100_000) {
    for (let i = 0; i < maxTasks; i++) {
      await new Promise<void>((resolve) => setImmediate(resolve))
      const task = this.tasks.shift()
      if (task) {
        task()
        continue
      }
      await new Promise<void>((resolve) => setImmediate(resolve))
      if (this.tasks.length === 0) return
    }
    throw new Error(`world did not settle after ${maxTasks} tasks`)
  }
}
