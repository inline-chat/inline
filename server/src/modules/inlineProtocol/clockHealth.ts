const DEFAULT_WARNING_MILLIS = 5_000
const DEFAULT_FAILURE_MILLIS = 20_000

export type InlineProtocolClockFailure =
  | "clock_offset_exceeded"
  | "clock_step_detected"

export type InlineProtocolClockWarning =
  | "clock_offset_warning"
  | "clock_step_warning"

export type InlineProtocolClockHealth = {
  readonly ok: boolean
  readonly status: "ok" | "warning" | "degraded"
  readonly offsetMillis: number
  readonly stepMillis: number
  readonly error?: InlineProtocolClockFailure
  readonly warning?: InlineProtocolClockWarning
}

export type InlineProtocolClockOptions = {
  readonly wallClock?: () => number
  readonly monotonicClock?: () => number
  readonly warningMillis?: number
  readonly failureMillis?: number
}

const checkedThreshold = (value: number, name: string): number => {
  if (!Number.isFinite(value) || value <= 0) {
    throw new RangeError(`${name} must be a positive finite number`)
  }
  return value
}

const rounded = (value: number): number => Math.round(value)

/**
 * Protects protocol time from large local wall-clock steps and, when supplied
 * a database time sample, from node-to-node UTC offset. A failure is latched:
 * protocol traffic remains disabled until the process restarts with a healthy
 * clock instead of silently resuming after generating unsafe message IDs.
 */
export class InlineProtocolClock {
  readonly #wallClock: () => number
  readonly #monotonicClock: () => number
  readonly #warningMillis: number
  readonly #failureMillis: number
  #lastWallMillis: number
  #lastMonotonicMillis: number
  #failure?: InlineProtocolClockFailure

  constructor(options: InlineProtocolClockOptions = {}) {
    this.#wallClock = options.wallClock ?? Date.now
    this.#monotonicClock = options.monotonicClock ?? performance.now.bind(performance)
    this.#warningMillis = checkedThreshold(
      options.warningMillis ?? DEFAULT_WARNING_MILLIS,
      "Clock warning threshold",
    )
    this.#failureMillis = checkedThreshold(
      options.failureMillis ?? DEFAULT_FAILURE_MILLIS,
      "Clock failure threshold",
    )
    if (this.#warningMillis >= this.#failureMillis) {
      throw new RangeError("Clock warning threshold must be lower than failure threshold")
    }
    this.#lastWallMillis = this.#wallClock()
    this.#lastMonotonicMillis = this.#monotonicClock()
  }

  sample(referenceTimeMillis?: number): InlineProtocolClockHealth {
    const wallMillis = this.#wallClock()
    const monotonicMillis = this.#monotonicClock()
    const stepMillis = (wallMillis - this.#lastWallMillis) -
      (monotonicMillis - this.#lastMonotonicMillis)
    const offsetMillis = referenceTimeMillis === undefined
      ? 0
      : wallMillis - referenceTimeMillis

    if (!this.#failure) {
      if (Math.abs(stepMillis) >= this.#failureMillis) {
        this.#failure = "clock_step_detected"
      } else if (Math.abs(offsetMillis) >= this.#failureMillis) {
        this.#failure = "clock_offset_exceeded"
      }
    }

    this.#lastWallMillis = wallMillis
    this.#lastMonotonicMillis = monotonicMillis

    if (this.#failure) {
      return {
        ok: false,
        status: "degraded",
        offsetMillis: rounded(offsetMillis),
        stepMillis: rounded(stepMillis),
        error: this.#failure,
      }
    }

    const warning = Math.abs(stepMillis) >= this.#warningMillis
      ? "clock_step_warning"
      : Math.abs(offsetMillis) >= this.#warningMillis
        ? "clock_offset_warning"
        : undefined

    return {
      ok: true,
      status: warning ? "warning" : "ok",
      offsetMillis: rounded(offsetMillis),
      stepMillis: rounded(stepMillis),
      ...(warning ? { warning } : {}),
    }
  }

  nowMilliseconds(): number {
    const health = this.sample()
    if (!health.ok) throw new RangeError("Inline Protocol clock is unhealthy")
    return this.#lastWallMillis
  }

  assertHealthy(): void {
    if (!this.sample().ok) throw new RangeError("Inline Protocol clock is unhealthy")
  }
}

export const inlineProtocolClock = new InlineProtocolClock()
