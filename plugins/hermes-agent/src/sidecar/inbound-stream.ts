import type { Writable } from "node:stream"

/** Retains a pending line across consumer replacement. A close after write is
 * uncertain, so replay keeps the original event identity for downstream dedup.
 */
export class InboundStream {
  private consumer: Writable | null = null
  private stopped = false
  private readonly changed = new Set<() => void>()

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

  close(): void {
    this.stopped = true
    const previous = this.consumer
    this.consumer = null
    this.wake()
    previous?.end()
  }

  async deliver(event: unknown): Promise<void> {
    const line = JSON.stringify(event) + "\n"
    while (!this.stopped) {
      const owner = this.consumer
      if (!owner) {
        await new Promise<void>((resolve) => this.changed.add(resolve))
        continue
      }
      let cleanup = () => {}
      const drained = new Promise<boolean>((resolve) => {
        const finish = (ok: boolean) => {
          cleanup()
          resolve(ok)
        }
        const onDrain = () => finish(true)
        const onChange = () => finish(false)
        cleanup = () => {
          owner.off("drain", onDrain)
          owner.off("close", onChange)
          owner.off("error", onChange)
          this.changed.delete(onChange)
        }
        owner.once("drain", onDrain)
        owner.once("close", onChange)
        owner.once("error", onChange)
        this.changed.add(onChange)
      })
      try {
        if (owner.destroyed || owner.writableEnded) {
          if (this.consumer === owner) this.consumer = null
          continue
        }
        const accepted = owner.write(line)
        if (this.consumer !== owner || this.stopped) continue
        if (accepted) return
        if ((await drained) && this.consumer === owner && !this.stopped) return
      } catch {
        if (this.consumer === owner) this.consumer = null
      } finally {
        cleanup()
      }
    }
    throw new Error("Inbound stream closed before delivery completed")
  }

  private wake(): void {
    for (const resolve of this.changed) resolve()
    this.changed.clear()
  }
}
