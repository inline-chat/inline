export class ReceiveMessageWindow {
  readonly #capacity: number
  readonly #accepted = new Set<bigint>()
  #highest: bigint | undefined

  constructor(capacity = 1000) {
    if (!Number.isSafeInteger(capacity) || capacity < 1) throw new RangeError("Receive window capacity must be positive")
    this.#capacity = capacity
  }

  claim(messageId: bigint): boolean {
    if (this.#accepted.has(messageId)) return false
    if (this.#highest !== undefined && messageId < this.#highest && this.#accepted.size >= this.#capacity) {
      const minimum = this.minimum
      if (minimum !== undefined && messageId < minimum) return false
    }
    this.#accepted.add(messageId)
    if (this.#highest === undefined || messageId > this.#highest) this.#highest = messageId
    if (this.#accepted.size > this.#capacity) {
      const ordered = [...this.#accepted].sort((left, right) => left < right ? -1 : left > right ? 1 : 0)
      for (let index = 0; index < ordered.length - this.#capacity; index += 1) this.#accepted.delete(ordered[index]!)
    }
    return true
  }

  has(messageId: bigint): boolean {
    return this.#accepted.has(messageId)
  }

  get minimum(): bigint | undefined {
    let minimum: bigint | undefined
    for (const value of this.#accepted) if (minimum === undefined || value < minimum) minimum = value
    return minimum
  }

  checkpoint(): { accepted: bigint[]; highest?: bigint } {
    return { accepted: [...this.#accepted], highest: this.#highest }
  }

  restore(checkpoint: { accepted: readonly bigint[]; highest?: bigint }): void {
    this.#accepted.clear()
    for (const messageId of checkpoint.accepted) this.#accepted.add(messageId)
    this.#highest = checkpoint.highest
  }
}

export class MessageIdGenerator {
  #last = 0n

  next(estimatedServerUnixMillis: number, randomLowBits: number, modulo: 0 | 1 | 3): bigint {
    if (!Number.isFinite(estimatedServerUnixMillis) || !Number.isSafeInteger(randomLowBits) || randomLowBits < 0 || randomLowBits > 0x3fffffff) {
      throw new RangeError("Invalid message-ID clock input")
    }
    const seconds = BigInt(Math.floor(estimatedServerUnixMillis / 1000))
    const millis = BigInt(Math.floor(estimatedServerUnixMillis % 1000))
    let candidate = (seconds << 32n) | ((millis << 32n) / 1000n) | (BigInt(randomLowBits) << 2n) | BigInt(modulo)
    candidate = (candidate & ~3n) | BigInt(modulo)
    if (candidate <= this.#last) candidate = ((this.#last + 4n) & ~3n) | BigInt(modulo)
    this.#last = candidate
    return candidate
  }
}

export class SequenceNumberGenerator {
  #contentCount = 0

  next(contentRelated: boolean): number {
    const sequenceNumber = this.#contentCount * 2 + (contentRelated ? 1 : 0)
    if (contentRelated) this.#contentCount += 1
    return sequenceNumber
  }
}

export interface MonotonicClock {
  nowMilliseconds(): number
}

export class AuthenticatedServerClock {
  #serverUnixMilliseconds: number | undefined
  #monotonicMilliseconds: number | undefined

  constructor(private readonly monotonic: MonotonicClock) {}

  sample(serverUnixSeconds: number): void {
    if (!Number.isSafeInteger(serverUnixSeconds) || serverUnixSeconds <= 0) {
      throw new RangeError("Invalid authenticated server-time sample")
    }
    const monotonicMilliseconds = this.monotonic.nowMilliseconds()
    if (!Number.isFinite(monotonicMilliseconds)) throw new RangeError("Invalid monotonic clock")
    this.#serverUnixMilliseconds = serverUnixSeconds * 1000
    this.#monotonicMilliseconds = monotonicMilliseconds
  }

  sampleMessageId(serverMessageId: bigint): void {
    if ((serverMessageId & 1n) !== 1n) throw new RangeError("Invalid authenticated server message ID")
    this.sample(Number(serverMessageId >> 32n))
  }

  nowMilliseconds(): number {
    if (this.#serverUnixMilliseconds === undefined || this.#monotonicMilliseconds === undefined) {
      throw new RangeError("Authenticated server time is unavailable")
    }
    const elapsed = this.monotonic.nowMilliseconds() - this.#monotonicMilliseconds
    if (!Number.isFinite(elapsed) || elapsed < 0) throw new RangeError("Monotonic clock discontinuity")
    return this.#serverUnixMilliseconds + elapsed
  }
}

export type MessageTimeValidation =
  | { kind: "valid" }
  | { kind: "bad"; errorCode: 16 | 17 | 18 | 20 }

export const validateInboundMessageId = (
  messageId: bigint,
  direction: "client" | "server",
  nowSeconds: number,
): MessageTimeValidation => {
  if (messageId === 0n || !Number.isFinite(nowSeconds)) return { kind: "bad", errorCode: 18 }
  const validDirection = direction === "client"
    ? (messageId & 3n) === 0n && (messageId & 0xffffffffn) !== 0n
    : (messageId & 1n) === 1n
  if (!validDirection) return { kind: "bad", errorCode: 18 }
  const seconds = Number(messageId >> 32n)
  if (seconds > nowSeconds + 30) return { kind: "bad", errorCode: 17 }
  if (seconds < nowSeconds - 300) return { kind: "bad", errorCode: 20 }
  return { kind: "valid" }
}

type ReceivedSequence = { messageId: bigint; sequenceNumber: number }

export class ReceiveSequenceValidator {
  readonly #received: ReceivedSequence[] = []

  validate(messageId: bigint, sequenceNumber: number, contentRelated: boolean): 32 | 33 | 34 | 35 | undefined {
    if (!Number.isSafeInteger(sequenceNumber) || sequenceNumber < 0) return 32
    if (contentRelated && sequenceNumber % 2 === 0) return 35
    if (!contentRelated && sequenceNumber % 2 !== 0) return 34
    let insertion = this.#received.findIndex((value) => value.messageId > messageId)
    if (insertion < 0) insertion = this.#received.length
    const previous = this.#received[insertion - 1]
    const next = this.#received[insertion]
    if (previous && previous.sequenceNumber > sequenceNumber) return 32
    if (next && next.sequenceNumber < sequenceNumber) return 33
    this.#received.splice(insertion, 0, { messageId, sequenceNumber })
    if (this.#received.length > 1000) this.#received.splice(0, this.#received.length - 1000)
    return undefined
  }

  checkpoint(): ReceivedSequence[] {
    return this.#received.map((value) => ({ ...value }))
  }

  restore(checkpoint: readonly ReceivedSequence[]): void {
    this.#received.splice(0, this.#received.length, ...checkpoint.map((value) => ({ ...value })))
  }
}

export class AcknowledgementQueue {
  readonly #pending = new Set<bigint>()

  add(messageId: bigint): void {
    if (this.#pending.size >= 8192 && !this.#pending.has(messageId)) throw new RangeError("Acknowledgement queue is full")
    this.#pending.add(messageId)
  }

  drain(maximum = 8192): bigint[] {
    if (!Number.isSafeInteger(maximum) || maximum < 1 || maximum > 8192) throw new RangeError("Invalid ACK batch size")
    const result: bigint[] = []
    for (const messageId of this.#pending) {
      result.push(messageId)
      this.#pending.delete(messageId)
      if (result.length === maximum) break
    }
    return result
  }
}

export type PendingMessage = {
  messageId: bigint
  sequenceNumber: number
  body: Uint8Array
}

export class PendingMessageCache {
  readonly #messages = new Map<bigint, PendingMessage>()

  constructor(private readonly capacity = 8192) {
    if (!Number.isSafeInteger(capacity) || capacity < 1 || capacity > 8192) throw new RangeError("Invalid pending-message capacity")
  }

  retain(message: PendingMessage): void {
    if (this.#messages.size >= this.capacity && !this.#messages.has(message.messageId)) {
      throw new RangeError("Pending-message cache is full")
    }
    this.#messages.set(message.messageId, { ...message, body: message.body.slice() })
  }

  acknowledge(messageIds: readonly bigint[]): void {
    for (const messageId of messageIds) this.#messages.delete(messageId)
  }

  resend(messageIds: readonly bigint[]): PendingMessage[] {
    return messageIds.flatMap((messageId) => {
      const message = this.#messages.get(messageId)
      return message ? [{ ...message, body: message.body.slice() }] : []
    })
  }

  state(messageIds: readonly bigint[]): Uint8Array {
    return Uint8Array.from(messageIds, (messageId) => this.#messages.has(messageId) ? 0x04 : 0x01)
  }

  dropRpcResult(requestMessageId: bigint): PendingMessage | undefined {
    for (const [messageId, message] of this.#messages) {
      if (message.body.length < 12) continue
      const view = new DataView(message.body.buffer, message.body.byteOffset, message.body.byteLength)
      if (view.getUint32(0, true) !== 0xf35c6d01 || view.getBigInt64(4, true) !== requestMessageId) continue
      this.#messages.delete(messageId)
      return { ...message, body: message.body.slice() }
    }
    return undefined
  }
}

export class BadMessageRecovery {
  readonly #outstanding = new Map<bigint, number>()

  add(messageId: bigint, sequenceNumber: number): void {
    if (this.#outstanding.size >= 8192 && !this.#outstanding.has(messageId)) throw new RangeError("Outstanding-message limit reached")
    this.#outstanding.set(messageId, sequenceNumber)
  }

  accept(input: {
    outerServerMessageId: bigint
    badMessageId: bigint
    badSequenceNumber: number
    errorCode: number
  }): { kind: "time"; serverSeconds: number } | { kind: "salt" } | { kind: "fatal" } {
    const sequence = this.#outstanding.get(input.badMessageId)
    if (sequence === undefined || sequence !== input.badSequenceNumber) return { kind: "fatal" }
    if (input.errorCode === 16 || input.errorCode === 17) {
      if ((input.outerServerMessageId & 1n) !== 1n) return { kind: "fatal" }
      return { kind: "time", serverSeconds: Number(input.outerServerMessageId >> 32n) }
    }
    if (input.errorCode === 48) return { kind: "salt" }
    return { kind: "fatal" }
  }
}
