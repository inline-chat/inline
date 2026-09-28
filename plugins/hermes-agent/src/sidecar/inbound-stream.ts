import { randomUUID } from "node:crypto"
import type { Writable } from "node:stream"

/** Holds the SDK receipt until Python acknowledges handling. Consumer replacement
 * replays the same delivery identity; this is an at-least-once process handoff,
 * not a durable exactly-once transaction with the gateway's effects.
 */
export class InboundStream {
  private consumer: Writable | null = null
  private stopped = false
  private readonly changed = new Set<() => void>()
  private readonly pending = new Map<string, { acknowledged: boolean }>()

  attach(consumer: Writable): void {
    if (this.stopped) {
      consumer.end()
      return
    }
    const previous = this.consumer
    this.consumer = consumer
    const retired = () => {
      if (this.consumer === consumer) {
        this.consumer = null
        this.wake()
      }
    }
    consumer.once("close", retired)
    consumer.on("error", retired)
    this.wake()
    previous?.end()
  }

  /** Repeated/unknown acknowledgements are harmless, including a retry after the
   * first acknowledgement succeeded but its HTTP response was lost.
   */
  acknowledge(deliveryId: string): void {
    const receipt = this.pending.get(deliveryId)
    if (!receipt) return
    receipt.acknowledged = true
    this.wake()
  }

  close(): void {
    this.stopped = true
    const previous = this.consumer
    this.consumer = null
    this.wake()
    previous?.end()
  }

  async deliver(event: unknown): Promise<void> {
    if (!event || typeof event !== "object" || Array.isArray(event)) {
      throw new Error("Inbound delivery requires an event object")
    }
    const deliveryId = randomUUID()
    const line = JSON.stringify({ ...event, _inlineDeliveryId: deliveryId }) + "\n"
    const receipt = { acknowledged: false }
    this.pending.set(deliveryId, receipt)
    let writtenTo: Writable | null = null
    try {
      while (!this.stopped) {
        if (receipt.acknowledged) return
        const owner = this.consumer
        if (owner && owner !== writtenTo) {
          try {
            if (owner.destroyed || owner.writableEnded) {
              if (this.consumer === owner) this.consumer = null
              continue
            }
            // Socket acceptance/drain is not handling acknowledgement. Each
            // SDK-owned pending delivery writes only once per consumer, and the
            // SDK bounds concurrent receipts/backpressure upstream.
            writtenTo = owner
            owner.write(line)
          } catch {
            if (this.consumer === owner) this.consumer = null
          }
          continue
        }
        await new Promise<void>((resolve) => this.changed.add(resolve))
      }
      throw new Error("Inbound stream closed before delivery completed")
    } finally {
      this.pending.delete(deliveryId)
    }
  }

  private wake(): void {
    for (const resolve of this.changed) resolve()
    this.changed.clear()
  }
}
