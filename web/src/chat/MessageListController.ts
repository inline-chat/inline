export type MessageListIntent = "bottom" | "history"

export type MessageListPhysicalState = {
  physicalBottom: boolean
  hasNewer: boolean
}

/**
 * Owns the user's list-position intent independently of Virtua's measured
 * scroll state. Virtua remains the sole row measurement/anchor engine; this
 * controller only decides when the product should ask it to align to the end.
 */
export class MessageListController {
  #intent: MessageListIntent
  #bottomRequestPending = false
  #epoch = 0
  #physicalBottom = false
  #hasNewer: boolean

  constructor({
    startsAtBottom,
    hasNewer,
  }: {
    startsAtBottom: boolean
    hasNewer: boolean
  }) {
    this.#intent = startsAtBottom ? "bottom" : "history"
    this.#hasNewer = hasNewer
  }

  get intent(): MessageListIntent {
    return this.#intent
  }

  get wantsBottom(): boolean {
    return this.#intent === "bottom"
  }

  get logicalBottom(): boolean {
    return this.#physicalBottom && !this.#hasNewer
  }

  get epoch(): number {
    return this.#epoch
  }

  isCurrent(epoch: number): boolean {
    return this.#epoch === epoch
  }

  /**
   * Begins one imperative end-alignment. Intermediate scroll events from
   * Virtua must not be mistaken for the user browsing history.
   */
  requestBottom(): number {
    this.#intent = "bottom"
    this.#bottomRequestPending = true
    this.#epoch += 1
    return this.#epoch
  }

  /** Explicit wheel/touch/keyboard intent always wins over pending work. */
  browseHistory(): void {
    this.#intent = "history"
    this.#bottomRequestPending = false
    this.#physicalBottom = false
    this.#epoch += 1
  }

  setHasNewer(hasNewer: boolean): void {
    this.#hasNewer = hasNewer
  }

  /** Records an in-flight native/programmatic scroll sample. */
  observePhysical({
    physicalBottom,
    hasNewer,
  }: MessageListPhysicalState): void {
    this.#physicalBottom = physicalBottom
    this.#hasNewer = hasNewer
    if (physicalBottom) {
      this.#intent = "bottom"
      this.#bottomRequestPending = false
    }
  }

  /** Finalizes a scroll sequence once Virtua reports native scroll end. */
  settlePhysical(state: MessageListPhysicalState): void {
    if (this.#bottomRequestPending && !state.physicalBottom) {
      // Virtua can emit scroll-end while a restored cache is still being
      // measured. That is an intermediate physical stop, not cancellation of
      // the product's end intent. Only reaching the end or explicit user
      // navigation resolves an outstanding bottom request.
      this.#physicalBottom = false
      this.#hasNewer = state.hasNewer
      return
    }
    this.#bottomRequestPending = false
    this.observePhysical(state)
  }
}

export const shouldFollowMessageListChange = ({
  appended,
  outgoingSend,
  wantsBottom,
}: {
  appended: boolean
  outgoingSend: boolean
  wantsBottom: boolean
}) => outgoingSend || (appended && wantsBottom)
