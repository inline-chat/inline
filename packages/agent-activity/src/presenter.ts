import type { Doc } from "./doc.js"
import { ProgressRenderer, type ActivityEvent, type RenderOp, type RendererOptions } from "./renderer.js"

export type MessageId = bigint

/** Sends and edits progress messages in one chat. */
export interface ProgressTransport {
  /** Sends a new message silently; resolves to its ID. */
  send(doc: Doc): Promise<MessageId>
  edit(messageId: MessageId, doc: Doc): Promise<void>
}

export type PresenterOptions = {
  /** Ordinary edits to one message are coalesced to one per window (the bridge uses 1.2 s). */
  editIntervalMs?: number
  /** A failed send or edit stops that message; the turn itself goes on. */
  onError?: (error: unknown, op: "send" | "edit") => void
  now?: () => number
  setTimer?: (callback: () => void, ms: number) => unknown
  clearTimer?: (timer: unknown) => void
}

type SlotState = {
  messageId?: MessageId | undefined
  pending?: Doc | undefined
  lastFingerprint?: string
  lastWriteAt: number
  timer?: unknown
  ended: boolean
  failed: boolean
}

export const EDIT_INTERVAL_MS = 1_200

/**
 * Performs render ops in order for one chat: the first op of a message sends
 * it, later ones edit it at most once per window, and attention and final
 * edits go out at once. `flush()` waits until everything queued has reached
 * the server, so callers can deliver the answer after "Worked for".
 */
export class ProgressPresenter {
  private readonly slots = new Map<number, SlotState>()
  private chain: Promise<void> = Promise.resolve()
  private readonly interval: number
  private readonly now: () => number
  private readonly setTimer: (callback: () => void, ms: number) => unknown
  private readonly clearTimer: (timer: unknown) => void

  constructor(private readonly transport: ProgressTransport, private readonly options: PresenterOptions = {}) {
    this.interval = options.editIntervalMs ?? EDIT_INTERVAL_MS
    this.now = options.now ?? Date.now
    this.setTimer = options.setTimer ?? ((callback, ms) => setTimeout(callback, ms))
    this.clearTimer = options.clearTimer ?? ((timer) => clearTimeout(timer as ReturnType<typeof setTimeout>))
  }

  push(ops: readonly RenderOp[]): void {
    for (const op of ops) {
      const slot = this.slotState(op.slot)
      if (slot.ended || slot.failed) continue
      slot.pending = op.doc
      if (op.type === "end") {
        slot.ended = true
        this.writeNow(op.slot, slot)
      } else if (slot.messageId === undefined && slot.lastFingerprint === undefined && slot.timer === undefined) {
        // The first op sends the message; anything that arrives while it is in flight waits its turn.
        this.writeNow(op.slot, slot)
      } else if (op.urgent || this.now() - slot.lastWriteAt >= this.interval) {
        this.writeNow(op.slot, slot)
      } else if (slot.timer === undefined) {
        slot.timer = this.setTimer(() => {
          slot.timer = undefined
          this.enqueue(op.slot, slot)
        }, Math.max(0, slot.lastWriteAt + this.interval - this.now()))
      }
    }
  }

  /** Writes anything still coalescing, then resolves once every queued send and edit has finished. */
  async flush(): Promise<void> {
    for (const [id, slot] of this.slots) if (slot.pending && !slot.failed) this.writeNow(id, slot)
    await this.chain
  }

  /** Message IDs of the progress messages sent so far, by slot. */
  messageIds(): MessageId[] {
    return [...this.slots.values()].flatMap((slot) => (slot.messageId === undefined ? [] : [slot.messageId]))
  }

  private slotState(id: number): SlotState {
    let slot = this.slots.get(id)
    if (!slot) {
      slot = { lastWriteAt: Number.NEGATIVE_INFINITY, ended: false, failed: false }
      this.slots.set(id, slot)
    }
    return slot
  }

  private writeNow(id: number, slot: SlotState): void {
    if (slot.timer !== undefined) {
      this.clearTimer(slot.timer)
      slot.timer = undefined
    }
    this.enqueue(id, slot)
  }

  private enqueue(id: number, slot: SlotState): void {
    // Mark the slot as started so a burst of first ops sends once.
    slot.lastFingerprint ??= ""
    this.chain = this.chain.then(() => this.write(id, slot))
  }

  private async write(_id: number, slot: SlotState): Promise<void> {
    const doc = slot.pending
    if (!doc || slot.failed) return
    slot.pending = undefined
    const fingerprint = fingerprintOf(doc)
    if (fingerprint === slot.lastFingerprint) return
    // A lost final edit would leave "Working" showing forever, so it gets one retry.
    const attempts = slot.ended && slot.messageId !== undefined ? 2 : 1
    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      try {
        if (slot.messageId === undefined) {
          slot.messageId = await this.transport.send(doc)
        } else {
          await this.transport.edit(slot.messageId, doc)
        }
        slot.lastFingerprint = fingerprint
        slot.lastWriteAt = this.now()
        return
      } catch (error) {
        if (attempt < attempts) continue
        slot.failed = true
        this.options.onError?.(error, slot.messageId === undefined ? "send" : "edit")
      }
    }
  }
}

function fingerprintOf(doc: Doc): string {
  return JSON.stringify(doc, (_key, value) => (typeof value === "bigint" ? value.toString() : value))
}

/**
 * One chat's Detailed progress: a renderer and a presenter together.
 * `apply` never throws and never waits; `flush` before delivering the answer.
 */
export class ProgressStream {
  readonly renderer: ProgressRenderer
  readonly presenter: ProgressPresenter

  constructor(transport: ProgressTransport, options: RendererOptions & PresenterOptions = {}) {
    this.renderer = new ProgressRenderer(options)
    this.presenter = new ProgressPresenter(transport, options)
  }

  apply(event: ActivityEvent, at?: number): void {
    try {
      this.presenter.push(this.renderer.apply(event, at))
    } catch (error) {
      // Presentation must never break the agent's turn.
      void error
    }
  }

  get isOpen(): boolean {
    return this.renderer.isOpen
  }

  flush(): Promise<void> {
    return this.presenter.flush()
  }
}
