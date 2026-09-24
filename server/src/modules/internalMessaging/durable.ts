import { ChatId, SessionId, SpaceId, UserId } from "@in/server/core/schema/identifiers"
import { Log } from "@in/server/utils/log"
import { outboundPublications, type OutboundPublication } from "./outbound"
import { internalMessaging } from "./service"

const log = new Log("internalMessaging.durable")
let lastUnavailableWarningAt = 0

export type DurableBucket =
  | { kind: "chat"; chatId: number }
  | { kind: "space"; spaceId: number }
  | { kind: "user"; userId: number }

export type DurableReference = {
  bucket: DurableBucket
  frontier: number
  senderUserId?: number
  excludeSessionId?: number
}

const bucketKey = (bucket: DurableBucket) => bucket.kind === "chat"
  ? `chat:${bucket.chatId}`
  : bucket.kind === "space"
    ? `space:${bucket.spaceId}`
    : `user:${bucket.userId}`

class DurablePublication implements OutboundPublication {
  readonly key: string
  private frontier: number
  private senderUserId: number | undefined
  private excludeSessionId: number | undefined

  constructor(input: DurableReference) {
    this.key = `durable:${bucketKey(input.bucket)}`
    this.bucket = input.bucket
    this.frontier = input.frontier
    this.senderUserId = input.senderUserId
    this.excludeSessionId = input.excludeSessionId
  }

  private readonly bucket: DurableBucket

  async run(): Promise<void> {
    const bucket = this.bucket.kind === "chat" ? { kind: "chat" as const, chatId: ChatId.make(this.bucket.chatId) }
      : this.bucket.kind === "space" ? { kind: "space" as const, spaceId: SpaceId.make(this.bucket.spaceId) }
      : { kind: "user" as const, userId: UserId.make(this.bucket.userId) }
    const outcome = await internalMessaging.publish({
      target: { kind: "cluster" },
      event: {
        kind: "DurableUpdatesAvailable", bucket, frontier: this.frontier,
        ...(this.senderUserId === undefined ? {} : { senderUserId: UserId.make(this.senderUserId) }),
        ...(this.excludeSessionId === undefined ? {} : { excludeSessionId: SessionId.make(this.excludeSessionId) }),
      },
    })
    if (outcome.status === "unavailable" && Date.now() - lastUnavailableWarningAt >= 60_000) {
      lastUnavailableWarningAt = Date.now()
      log.warn("Broker unavailable after durable commit", { bucket: this.bucket.kind })
    }
  }

  merge(next: OutboundPublication): void {
    if (!(next instanceof DurablePublication) || next.key !== this.key) {
      throw new Error("Durable publication merged with an incompatible outbound hint")
    }
    this.frontier = Math.max(this.frontier, next.frontier)
    // A coalesced frontier represents every earlier update. Retaining an
    // exclusion from only one update could make that session miss another.
    if (this.senderUserId !== next.senderUserId || this.excludeSessionId !== next.excludeSessionId) {
      this.senderUserId = undefined
      this.excludeSessionId = undefined
    }
  }
}

/**
 * Enqueue a post-commit durable hint without waiting for the broker. The
 * bounded dispatcher owns execution, coalescing, error handling and shutdown.
 */
export function publishDurableReference(input: DurableReference): void {
  outboundPublications.enqueue(new DurablePublication(input))
}
