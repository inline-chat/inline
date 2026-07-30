import type { BotChatSettingsResponse } from "@inline-chat/protocol/core"
import { unreachableBotChatSettingsResponse } from "./validation"

export const BOT_CHAT_SETTINGS_ANSWER_TIMEOUT_MS = 10_000
const MAX_PENDING_REQUESTS = 10_000
const MAX_PENDING_REQUESTS_PER_KEY = 8

type PendingRequest = {
  botUserId: number
  fairnessKey: string
  resolve: (response: BotChatSettingsResponse) => void
  timer: ReturnType<typeof setTimeout>
}

export type BotChatSettingsRequestScope = {
  botUserId: number
  actorUserId: number
  chatId: number
}

type BrokerOptions = {
  answerTimeoutMs?: number
  maxPendingRequests?: number
  maxPendingRequestsPerKey?: number
  generateId?: () => bigint
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

  constructor(options: BrokerOptions = {}) {
    this.answerTimeoutMs = options.answerTimeoutMs ?? BOT_CHAT_SETTINGS_ANSWER_TIMEOUT_MS
    this.maxPendingRequests = options.maxPendingRequests ?? MAX_PENDING_REQUESTS
    this.maxPendingRequestsPerKey = options.maxPendingRequestsPerKey ?? MAX_PENDING_REQUESTS_PER_KEY
    this.generateId = options.generateId ?? randomId64
  }

  create(scope: BotChatSettingsRequestScope): { requestId: bigint; response: Promise<BotChatSettingsResponse> } {
    const fairnessKey = `${scope.botUserId}:${scope.actorUserId}:${scope.chatId}`
    const pendingForKey = [...this.pending].filter(([, pending]) => pending.fairnessKey === fairnessKey)
    if (pendingForKey.length >= this.maxPendingRequestsPerKey) {
      const oldestForKey = pendingForKey[0]
      if (oldestForKey) this.resolveSystem(oldestForKey[0], unreachableBotChatSettingsResponse())
    }
    if (this.pending.size >= this.maxPendingRequests) {
      const oldestId = this.pending.keys().next().value
      if (oldestId !== undefined) this.resolveSystem(oldestId, unreachableBotChatSettingsResponse())
    }

    const requestId = this.nextId()
    const response = new Promise<BotChatSettingsResponse>((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(requestId)
        resolve(unreachableBotChatSettingsResponse())
      }, this.answerTimeoutMs)
      this.pending.set(requestId, { botUserId: scope.botUserId, fairnessKey, resolve, timer })
    })
    return { requestId, response }
  }

  answer(requestId: bigint, botUserId: number, response: BotChatSettingsResponse): boolean {
    const pending = this.pending.get(requestId)
    if (!pending || pending.botUserId !== botUserId) return false
    this.resolve(requestId, pending, response)
    return true
  }

  resolveSystem(requestId: bigint, response: BotChatSettingsResponse): boolean {
    const pending = this.pending.get(requestId)
    if (!pending) return false
    this.resolve(requestId, pending, response)
    return true
  }

  shutdown(): void {
    const response = unreachableBotChatSettingsResponse()
    for (const [requestId, pending] of this.pending) this.resolve(requestId, pending, response)
  }

  get pendingCount(): number {
    return this.pending.size
  }

  private resolve(requestId: bigint, pending: PendingRequest, response: BotChatSettingsResponse): void {
    clearTimeout(pending.timer)
    this.pending.delete(requestId)
    pending.resolve(response)
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
