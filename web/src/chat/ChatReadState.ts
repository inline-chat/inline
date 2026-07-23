import { compareInlineIds, type MessageID } from "@inline/ids"

export type ChatReadStateObservation = {
  active: boolean
  atBottom: boolean
  needsRead: boolean
  latestMessageId?: MessageID
}

export type ChatReadStateCoordinatorOptions = {
  send: (maxId: MessageID) => Promise<void>
  debounceMs?: number
  onError?: (error: unknown) => void
}

const laterMessageId = (
  left: MessageID | undefined,
  right: MessageID,
) =>
  left == null || compareInlineIds(right, left) > 0
    ? right
    : left

/**
 * Coalesces renderer visibility observations into ordered read mutations.
 * There is at most one local-acceptance commit in flight and one latest
 * boundary waiting behind it, regardless of scroll/resize/realtime render
 * frequency. `activate` makes the lifecycle safe under React Strict Mode's
 * development setup/cleanup/setup probe.
 */
export class ChatReadStateCoordinator {
  private readonly send: (maxId: MessageID) => Promise<void>
  private readonly debounceMs: number
  private readonly onError: (error: unknown) => void
  private queuedMaxId?: MessageID
  private lastSucceededMaxId?: MessageID
  private inFlightMaxId?: MessageID
  private timer?: ReturnType<typeof setTimeout>
  private inFlight = false
  private disposed = false

  constructor(options: ChatReadStateCoordinatorOptions) {
    this.send = options.send
    this.debounceMs = options.debounceMs ?? 150
    this.onError = options.onError ?? (() => undefined)
  }

  activate() {
    this.disposed = false
  }

  observe(observation: ChatReadStateObservation) {
    const { active, atBottom, needsRead, latestMessageId } =
      observation
    if (
      this.disposed ||
      !active ||
      !atBottom ||
      !needsRead ||
      latestMessageId == null
    ) {
      return
    }
    const acceptedMaxId =
      this.inFlightMaxId == null
        ? this.lastSucceededMaxId
        : laterMessageId(
            this.lastSucceededMaxId,
            this.inFlightMaxId,
          )
    if (
      acceptedMaxId != null &&
      compareInlineIds(latestMessageId, acceptedMaxId) <= 0
    ) {
      return
    }

    this.queuedMaxId = laterMessageId(
      this.queuedMaxId,
      latestMessageId,
    )
    this.schedule()
  }

  dispose() {
    this.disposed = true
    if (this.timer) clearTimeout(this.timer)
    this.timer = undefined
    this.queuedMaxId = undefined
  }

  private schedule() {
    if (
      this.disposed ||
      this.inFlight ||
      this.timer ||
      this.queuedMaxId == null
    ) {
      return
    }
    this.timer = setTimeout(() => {
      this.timer = undefined
      void this.flush()
    }, this.debounceMs)
  }

  private async flush() {
    const maxId = this.queuedMaxId
    if (this.disposed || this.inFlight || maxId == null) return
    this.queuedMaxId = undefined
    this.inFlight = true
    this.inFlightMaxId = maxId
    try {
      await this.send(maxId)
      this.lastSucceededMaxId = laterMessageId(
        this.lastSucceededMaxId,
        maxId,
      )
    } catch (error) {
      this.onError(error)
    } finally {
      this.inFlight = false
      this.inFlightMaxId = undefined
      this.schedule()
    }
  }
}

export const isChatDocumentActive = (
  document: Pick<Document, "visibilityState" | "hasFocus">,
) =>
  document.visibilityState === "visible" &&
  document.hasFocus()
