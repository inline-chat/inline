const HISTORY_CONTEXT_MARKER = "[Chat messages since your last reply - for context]"
const CURRENT_MESSAGE_MARKER = "[Current message - respond to this]"
const MAX_HISTORY_KEYS = 1000

export const DEFAULT_GROUP_HISTORY_LIMIT = 50

export type HistoryEntry = {
  sender: string
  body: string
  timestamp?: number
  messageId?: string
}

export type InlineTypingCallbacks = {
  onReplyStart: () => Promise<void>
  onIdle?: () => void
  onCleanup?: () => void
}

export type CreateInlineTypingCallbacksParams = {
  start: () => Promise<void>
  stop?: () => Promise<void>
  onStartError: (err: unknown) => void
  onStopError?: (err: unknown) => void
  keepaliveIntervalMs?: number
  maxConsecutiveFailures?: number
  maxDurationMs?: number
}

export type InlineChannelReplyPipeline = {
  onModelSelected?: (ctx: unknown) => void
  responsePrefix?: string
  enableSlackInteractiveReplies?: boolean
  responsePrefixContextProvider?: () => unknown
  typingCallbacks?: InlineTypingCallbacks
}

function evictOldHistoryKeys<T>(historyMap: Map<string, T[]>, maxKeys = MAX_HISTORY_KEYS): void {
  if (historyMap.size <= maxKeys) {
    return
  }
  const keysToDelete = historyMap.size - maxKeys
  const iterator = historyMap.keys()
  for (let index = 0; index < keysToDelete; index += 1) {
    const key = iterator.next().value
    if (key !== undefined) {
      historyMap.delete(key)
    }
  }
}

function buildHistoryContext(params: {
  historyText: string
  currentMessage: string
  lineBreak?: string
}): string {
  const lineBreak = params.lineBreak ?? "\n"
  if (!params.historyText.trim()) {
    return params.currentMessage
  }
  return [
    HISTORY_CONTEXT_MARKER,
    params.historyText,
    "",
    CURRENT_MESSAGE_MARKER,
    params.currentMessage,
  ].join(lineBreak)
}

function appendHistoryEntry<T extends HistoryEntry>(params: {
  historyMap: Map<string, T[]>
  historyKey: string
  entry: T
  limit: number
}): T[] {
  if (params.limit <= 0) {
    return []
  }
  const history = params.historyMap.get(params.historyKey) ?? []
  history.push(params.entry)
  while (history.length > params.limit) {
    history.shift()
  }
  if (params.historyMap.has(params.historyKey)) {
    params.historyMap.delete(params.historyKey)
  }
  params.historyMap.set(params.historyKey, history)
  evictOldHistoryKeys(params.historyMap)
  return history
}

function buildHistoryContextFromEntries(params: {
  entries: HistoryEntry[]
  currentMessage: string
  formatEntry: (entry: HistoryEntry) => string
  lineBreak?: string
  excludeLast?: boolean
}): string {
  const lineBreak = params.lineBreak ?? "\n"
  const entries = params.excludeLast === false ? params.entries : params.entries.slice(0, -1)
  if (entries.length === 0) {
    return params.currentMessage
  }
  return buildHistoryContext({
    historyText: entries.map(params.formatEntry).join(lineBreak),
    currentMessage: params.currentMessage,
    lineBreak,
  })
}

export function buildPendingHistoryContextFromMap(params: {
  historyMap: Map<string, HistoryEntry[]>
  historyKey: string
  limit: number
  currentMessage: string
  formatEntry: (entry: HistoryEntry) => string
  lineBreak?: string
}): string {
  if (params.limit <= 0) {
    return params.currentMessage
  }
  const entries = params.historyMap.get(params.historyKey) ?? []
  return buildHistoryContextFromEntries({
    entries,
    currentMessage: params.currentMessage,
    formatEntry: params.formatEntry,
    ...(params.lineBreak !== undefined ? { lineBreak: params.lineBreak } : {}),
    excludeLast: false,
  })
}

export function clearHistoryEntriesIfEnabled(params: {
  historyMap: Map<string, HistoryEntry[]>
  historyKey: string
  limit: number
}): void {
  if (params.limit <= 0) {
    return
  }
  params.historyMap.set(params.historyKey, [])
}

export function recordPendingHistoryEntryIfEnabled<T extends HistoryEntry>(params: {
  historyMap: Map<string, T[]>
  historyKey: string
  entry?: T | null
  limit: number
}): T[] {
  if (!params.entry || params.limit <= 0) {
    return []
  }
  return appendHistoryEntry({
    historyMap: params.historyMap,
    historyKey: params.historyKey,
    entry: params.entry,
    limit: params.limit,
  })
}

export function createMessageToolButtonsSchemaCompat() {
  return {
    type: "array",
    description: "Button rows for channels that support button-style actions.",
    items: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["text", "callback_data"],
        properties: {
          text: { type: "string" },
          callback_data: { type: "string" },
          style: { type: "string", enum: ["danger", "success", "primary"] },
        },
      },
    },
  } as unknown as Record<string, unknown>
}

export function extensionForMimeCompat(mime: string | undefined): string | undefined {
  const normalized = mime?.trim().toLowerCase()
  if (!normalized) return undefined
  const directMap: Record<string, string> = {
    "image/jpeg": "jpg",
    "image/jpg": "jpg",
    "image/png": "png",
    "image/gif": "gif",
    "image/webp": "webp",
    "video/mp4": "mp4",
    "audio/mpeg": "mp3",
    "audio/mp4": "m4a",
    "audio/wav": "wav",
    "audio/ogg": "ogg",
    "application/pdf": "pdf",
    "text/plain": "txt",
  }
  const mapped = directMap[normalized]
  if (mapped) return mapped
  const [, subtype] = normalized.split("/", 2)
  return subtype?.split("+", 1)[0] || undefined
}

function createInlineTypingCallbacks(params: CreateInlineTypingCallbacksParams): InlineTypingCallbacks {
  const keepaliveIntervalMs = params.keepaliveIntervalMs ?? 3_000
  const maxConsecutiveFailures = Math.max(1, params.maxConsecutiveFailures ?? 2)
  const maxDurationMs = params.maxDurationMs ?? 60_000
  let closed = false
  let stopSent = false
  let consecutiveFailures = 0
  let keepaliveTimer: ReturnType<typeof setInterval> | undefined
  let ttlTimer: ReturnType<typeof setTimeout> | undefined

  const clearTimers = () => {
    if (keepaliveTimer) {
      clearInterval(keepaliveTimer)
      keepaliveTimer = undefined
    }
    if (ttlTimer) {
      clearTimeout(ttlTimer)
      ttlTimer = undefined
    }
  }

  const fireStop = () => {
    closed = true
    clearTimers()
    if (!params.stop || stopSent) {
      return
    }
    stopSent = true
    void params.stop().catch((err) => (params.onStopError ?? params.onStartError)(err))
  }

  const fireStart = async () => {
    if (closed) return
    try {
      await params.start()
      consecutiveFailures = 0
    } catch (err) {
      consecutiveFailures += 1
      params.onStartError(err)
      if (consecutiveFailures >= maxConsecutiveFailures) {
        fireStop()
      }
    }
  }

  return {
    onReplyStart: async () => {
      if (closed) return
      stopSent = false
      consecutiveFailures = 0
      clearTimers()
      await fireStart()
      if (closed) return
      keepaliveTimer = setInterval(() => {
        void fireStart()
      }, keepaliveIntervalMs)
      if (maxDurationMs > 0) {
        ttlTimer = setTimeout(() => {
          fireStop()
        }, maxDurationMs)
      }
    },
    onIdle: fireStop,
    onCleanup: fireStop,
  }
}

export async function createChannelReplyPipelineCompat(params: {
  cfg: unknown
  agentId: string
  channel?: string
  accountId?: string
  typing?: CreateInlineTypingCallbacksParams
  typingCallbacks?: InlineTypingCallbacks
}): Promise<InlineChannelReplyPipeline> {
  try {
    const sdk = await import("openclaw/plugin-sdk/channel-reply-pipeline")
    return sdk.createChannelReplyPipeline(params as never) as InlineChannelReplyPipeline
  } catch {
    return {
      onModelSelected: () => {},
      ...(params.typingCallbacks
        ? { typingCallbacks: params.typingCallbacks }
        : params.typing
        ? { typingCallbacks: createInlineTypingCallbacks(params.typing) }
        : {}),
    }
  }
}

export async function loadNativeCommandHelpersCompat(): Promise<{
  available: boolean
  listNativeCommandSpecsForConfig: (
    cfg: unknown,
    params?: { skillCommands?: Array<{ name: string; description: string }> },
  ) => Array<{ name: string; description: string }>
  listSkillCommandsForAgents: (params: {
    cfg: unknown
  }) => Array<{ name: string; description: string }>
}> {
  try {
    const sdk = await import("openclaw/plugin-sdk/command-auth")
    const listNativeCommandSpecsForConfig =
      typeof sdk.listNativeCommandSpecsForConfig === "function"
        ? (sdk.listNativeCommandSpecsForConfig as (
            cfg: unknown,
            params?: { skillCommands?: Array<{ name: string; description: string }> },
          ) => Array<{ name: string; description: string }>)
        : null
    const listSkillCommandsForAgents =
      typeof sdk.listSkillCommandsForAgents === "function"
        ? (sdk.listSkillCommandsForAgents as (params: {
            cfg: unknown
          }) => Array<{ name: string; description: string }>)
        : null
    if (!listNativeCommandSpecsForConfig || !listSkillCommandsForAgents) {
      throw new Error("command-auth helpers unavailable")
    }
    return {
      available: true,
      listNativeCommandSpecsForConfig,
      listSkillCommandsForAgents,
    }
  } catch {
    return {
      available: false,
      listNativeCommandSpecsForConfig: () => [],
      listSkillCommandsForAgents: () => [],
    }
  }
}

export async function loadPluginCommandSpecsCompat(provider: string): Promise<{
  available: boolean
  specs: Array<{ name: string; description: string }>
}> {
  try {
    const sdk = await import("openclaw/plugin-sdk/plugin-runtime")
    if (typeof sdk.getPluginCommandSpecs !== "function") {
      throw new Error("plugin runtime command helper unavailable")
    }
    return {
      available: true,
      specs: (sdk.getPluginCommandSpecs as (provider?: string) => Array<{ name: string; description: string }>)(provider),
    }
  } catch {
    return {
      available: false,
      specs: [],
    }
  }
}
