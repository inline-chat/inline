/**
 * The UI side of the demo control channel. Any tab of a demo account can
 * drive the simulated world, wherever the leader's worker runs: commands go
 * out on the demo's `BroadcastChannel`, status and results come back on it.
 */
import { signal, type ReadSignal } from "@inline/reactive"
import {
  isDemoEvent,
  type DemoCommand,
  type DemoResult,
  type DemoStatus,
} from "../../../packages/client/src/testing/demo-protocol"

/** Commands as a caller writes them; the control assigns the `id`. */
export type DemoCommandInput = DemoCommand extends infer C ? (C extends unknown ? Omit<C, "id"> : never) : never

export type DemoControl = {
  /** The world's latest status; `undefined` until the worker reports. */
  readonly status: ReadSignal<DemoStatus | undefined>
  /**
   * Run a command. Resolves with the world's result, or with `ok: false` if
   * no worker answers within `timeoutMs` (default 15 s). Commands sent before
   * the worker is up wait for it.
   */
  send(command: DemoCommandInput, options?: { timeoutMs?: number }): Promise<DemoResult>
  close(): void
}

type Pending = {
  command: DemoCommand
  resolve: (result: DemoResult) => void
  timer: ReturnType<typeof setTimeout>
  sent: boolean
}

export const connectDemoControl = (channelName: string): DemoControl => {
  const channel = new BroadcastChannel(channelName)
  const status = signal<DemoStatus | undefined>(undefined)
  const pending = new Map<number, Pending>()
  let nextId = Math.floor(Math.random() * 1_000_000) * 1_000
  let alive = false
  let closed = false

  const post = (command: DemoCommand) => {
    try {
      channel.postMessage(command)
    } catch {
      // A closed channel: the pending command times out.
    }
  }

  const flush = () => {
    for (const entry of pending.values()) {
      if (entry.sent) continue
      entry.sent = true
      post(entry.command)
    }
  }

  channel.addEventListener("message", (event: MessageEvent<unknown>) => {
    const data = event.data
    if (!isDemoEvent(data)) return
    if (data.kind === "status") {
      status.set(data)
      if (!alive) {
        alive = true
        flush()
      }
      return
    }
    if (data.id == null) return
    const entry = pending.get(data.id)
    if (!entry) return
    pending.delete(data.id)
    clearTimeout(entry.timer)
    entry.resolve(data)
  })

  // Ask for a status until a worker answers; it may still be starting.
  const ping = setInterval(() => {
    if (alive || closed) {
      clearInterval(ping)
      return
    }
    post({ kind: "requestStatus" })
  }, 500)
  post({ kind: "requestStatus" })

  return {
    status,
    send(input, options = {}) {
      if (closed) return Promise.resolve({ kind: "result", ok: false, error: "The demo control is closed" })
      const id = (nextId += 1)
      const command = { ...input, id } as DemoCommand
      return new Promise<DemoResult>((resolve) => {
        const timer = setTimeout(() => {
          pending.delete(id)
          resolve({ kind: "result", id, ok: false, error: "No answer from the demo worker" })
        }, options.timeoutMs ?? 15_000)
        pending.set(id, { command, resolve, timer, sent: alive })
        if (alive) post(command)
      })
    },
    close() {
      if (closed) return
      closed = true
      clearInterval(ping)
      for (const [id, entry] of pending) {
        clearTimeout(entry.timer)
        entry.resolve({ kind: "result", id, ok: false, error: "The demo control is closed" })
      }
      pending.clear()
      channel.close()
    },
  }
}
