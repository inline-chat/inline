import type { BotFilesystemResponse } from "@inline-chat/protocol/core"

const unavailable = (): BotFilesystemResponse => ({ result: { oneofKind: "problem", problem: "The remote machine is unavailable. Try again." } })
type Pending = { bot: number; connectionId: string; resolve: (value: BotFilesystemResponse) => void; timer: ReturnType<typeof setTimeout> }

/** Private replies only: no filesystem payload is logged or persisted. */
export class BotFilesystemBroker {
  private pending = new Map<bigint, Pending>()
  constructor(private timeoutMs = 10_000) {}

  create(bot: number, connectionId: string): { id: bigint; response: Promise<BotFilesystemResponse> } | undefined {
    if (this.pending.size >= 128 || [...this.pending.values()].filter((p) => p.bot === bot).length >= 8) return
    let id: bigint
    do { id = new DataView(crypto.getRandomValues(new Uint8Array(8)).buffer).getBigUint64(0) } while (id === 0n || this.pending.has(id))
    const response = new Promise<BotFilesystemResponse>((resolve) => {
      const timer = setTimeout(() => this.answer(id, bot, connectionId, unavailable()), this.timeoutMs)
      this.pending.set(id, { bot, connectionId, resolve, timer })
    })
    return { id, response }
  }

  answer(id: bigint, bot: number, connectionId: string, response: BotFilesystemResponse): boolean {
    const pending = this.pending.get(id)
    if (!pending || pending.bot !== bot || pending.connectionId !== connectionId) return false
    clearTimeout(pending.timer)
    this.pending.delete(id)
    pending.resolve(response)
    return true
  }

  shutdown(): void {
    for (const [id, pending] of this.pending) this.answer(id, pending.bot, pending.connectionId, unavailable())
  }
}
export const botFilesystemBroker = new BotFilesystemBroker()
