import type { BotChatSettingsResponse } from "@inline-chat/protocol/core"
import { Log } from "@in/server/utils/log"
import { unreachableBotChatSettingsResponse } from "./validation"

export const BOT_CHAT_SETTINGS_ANSWER_TIMEOUT_MS = 10_000
const MAX_PENDING_REQUESTS = 10_000
const MAX_PENDING_REQUESTS_PER_KEY = 8

type PendingRequest = {
  botUserId: number
  fairnessKey: string
  operation: BotChatSettingsOperation
  startedAt: number
  recipientCount?: number
  resolve: (response: BotChatSettingsResponse) => void
  timer: ReturnType<typeof setTimeout>
}

export type BotChatSettingsOperation = "request" | "mutation"

export type BotChatSettingsRequestScope = {
  botUserId: number
  actorUserId: number
  chatId: number
  operation: BotChatSettingsOperation
}

export type BotChatSettingsResolutionReason =
  | "answer"
  | "dispatch_failure"
  | "global_capacity"
  | "no_recipient"
  | "per_key_capacity"
  | "shutdown"
  | "timeout"

export type BotChatSettingsBrokerDiagnostic = {
  phase: "answer_rejected" | "dispatched" | "resolved"
  operation: BotChatSettingsOperation | "unknown"
  pendingCount: number
  elapsedMs?: number
  outcome?: string
  reason?: BotChatSettingsResolutionReason
  recipientCount?: number
}

type BrokerOptions = {
  answerTimeoutMs?: number
  maxPendingRequests?: number
  maxPendingRequestsPerKey?: number
  generateId?: () => bigint
  now?: () => number
  onDiagnostic?: (diagnostic: BotChatSettingsBrokerDiagnostic) => void
}

const log = new Log("botChatSettings.broker")

const logDiagnostic = (diagnostic: BotChatSettingsBrokerDiagnostic): void => {
  const isExpectedDispatch = diagnostic.phase === "dispatched" && (diagnostic.recipientCount ?? 0) <= 1
  const isFastDocument = diagnostic.phase === "resolved"
    && diagnostic.reason === "answer"
    && diagnostic.outcome === "document"
    && (diagnostic.elapsedMs ?? 0) < 1_000
  if (isExpectedDispatch || isFastDocument) return
  log.warn("BOT_SETTINGS_TRACE", diagnostic)
}

const randomId64 = (): bigint => {
  const bytes = crypto.getRandomValues(new Uint8Array(8))
  let hex = ""
  for (const byte of bytes) hex += byte.toString(16).padStart(2, "0")
  const id = BigInt(`0x${hex}`)
  return id === 0n ? 1n : id
}

export class BotChatSettingsBroker {
  private readonly pending = new Map<bigint, PendingRequest>()
  private readonly answerTimeoutMs: number
  private readonly maxPendingRequests: number
  private readonly maxPendingRequestsPerKey: number
  private readonly generateId: () => bigint
  private readonly now: () => number
  private readonly onDiagnostic: (diagnostic: BotChatSettingsBrokerDiagnostic) => void

  constructor(options: BrokerOptions = {}) {
    this.answerTimeoutMs = options.answerTimeoutMs ?? BOT_CHAT_SETTINGS_ANSWER_TIMEOUT_MS
    this.maxPendingRequests = options.maxPendingRequests ?? MAX_PENDING_REQUESTS
    this.maxPendingRequestsPerKey = options.maxPendingRequestsPerKey ?? MAX_PENDING_REQUESTS_PER_KEY
    this.generateId = options.generateId ?? randomId64
    this.now = options.now ?? Date.now
    this.onDiagnostic = options.onDiagnostic ?? logDiagnostic
  }

  create(scope: BotChatSettingsRequestScope): { requestId: bigint; response: Promise<BotChatSettingsResponse> } {
    const fairnessKey = `${scope.botUserId}:${scope.actorUserId}:${scope.chatId}`
    const pendingForKey = [...this.pending].filter(([, pending]) => pending.fairnessKey === fairnessKey)
    if (pendingForKey.length >= this.maxPendingRequestsPerKey) {
      const oldestForKey = pendingForKey[0]
      if (oldestForKey) {
        this.resolveSystem(oldestForKey[0], unreachableBotChatSettingsResponse(), "per_key_capacity")
      }
    }
    if (this.pending.size >= this.maxPendingRequests) {
      const oldestId = this.pending.keys().next().value
      if (oldestId !== undefined) {
        this.resolveSystem(oldestId, unreachableBotChatSettingsResponse(), "global_capacity")
      }
    }

    const requestId = this.nextId()
    const response = new Promise<BotChatSettingsResponse>((resolve) => {
      const timer = setTimeout(() => {
        const pending = this.pending.get(requestId)
        if (pending) this.resolve(requestId, pending, unreachableBotChatSettingsResponse(), "timeout")
      }, this.answerTimeoutMs)
      this.pending.set(requestId, {
        botUserId: scope.botUserId,
        fairnessKey,
        operation: scope.operation,
        startedAt: this.now(),
        resolve,
        timer,
      })
    })
    return { requestId, response }
  }

  markDispatched(requestId: bigint, recipientCount: number): boolean {
    const pending = this.pending.get(requestId)
    if (!pending) return false
    pending.recipientCount = recipientCount
    this.emit({
      phase: "dispatched",
      operation: pending.operation,
      pendingCount: this.pending.size,
      recipientCount,
    })
    return true
  }

  answer(requestId: bigint, botUserId: number, response: BotChatSettingsResponse): boolean {
    const pending = this.pending.get(requestId)
    if (!pending || pending.botUserId !== botUserId) {
      this.emit({
        phase: "answer_rejected",
        operation: pending?.operation ?? "unknown",
        pendingCount: this.pending.size,
        ...(pending ? { elapsedMs: this.elapsedMs(pending) } : {}),
      })
      return false
    }
    this.resolve(requestId, pending, response, "answer")
    return true
  }

  resolveSystem(
    requestId: bigint,
    response: BotChatSettingsResponse,
    reason: Exclude<BotChatSettingsResolutionReason, "answer">,
  ): boolean {
    const pending = this.pending.get(requestId)
    if (!pending) return false
    this.resolve(requestId, pending, response, reason)
    return true
  }

  shutdown(): void {
    const response = unreachableBotChatSettingsResponse()
    for (const [requestId, pending] of this.pending) this.resolve(requestId, pending, response, "shutdown")
  }

  get pendingCount(): number {
    return this.pending.size
  }

  private resolve(
    requestId: bigint,
    pending: PendingRequest,
    response: BotChatSettingsResponse,
    reason: BotChatSettingsResolutionReason,
  ): void {
    clearTimeout(pending.timer)
    this.pending.delete(requestId)
    this.emit({
      phase: "resolved",
      operation: pending.operation,
      pendingCount: this.pending.size,
      elapsedMs: this.elapsedMs(pending),
      outcome: this.outcome(response),
      reason,
      ...(pending.recipientCount === undefined ? {} : { recipientCount: pending.recipientCount }),
    })
    pending.resolve(response)
  }

  private elapsedMs(pending: PendingRequest): number {
    return Math.max(0, this.now() - pending.startedAt)
  }

  private outcome(response: BotChatSettingsResponse): string {
    switch (response.result.oneofKind) {
      case "document": return "document"
      case "problem": return `problem:${response.result.problem.code}`
      default: return "invalid"
    }
  }

  private emit(diagnostic: BotChatSettingsBrokerDiagnostic): void {
    try {
      this.onDiagnostic(diagnostic)
    } catch {
      // Diagnostics must never affect the user request.
    }
  }

  private nextId(): bigint {
    for (let attempt = 0; attempt < 16; attempt += 1) {
      const requestId = this.generateId()
      if (requestId > 0n && !this.pending.has(requestId)) return requestId
    }
    throw new Error("Unable to allocate bot settings request id")
  }
}

export const botChatSettingsBroker = new BotChatSettingsBroker()
export const shutdownBotChatSettingsBroker = (): void => botChatSettingsBroker.shutdown()
