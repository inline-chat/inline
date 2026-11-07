import type { InlineTypingCallbacks } from "../sdk-runtime-compat.js"
import { BotPresenceState_Kind, InlineSdkClient, Method } from "@inline-chat/realtime-sdk"
import { sendInlineWorkingAction } from "./compose-action.js"
import { type InlineReplyPayload, isRecord } from "./monitor-shared.js"

const INLINE_BOT_PRESENCE_IDLE_DELAY_MS = 8_000
const INLINE_BOT_PRESENCE_FINISH_IDLE_DELAY_MS = 8_000
const INLINE_BOT_PRESENCE_GESTURE_MS = 1_400
const INLINE_BOT_PRESENCE_FAILED_MS = 8_000
const INLINE_BOT_PRESENCE_COMMENT_MAX_LENGTH = 30

type InlineBotPresenceKind =
  | "idle"
  | "happy"
  | "waving"
  | "jumping"
  | "failed"
  | "waiting"
  | "running"
  | "review"

type InlineBotPresenceSignal = {
  kind: InlineBotPresenceKind
  comment?: string
}

export function buildInlineTypingDispatcherOptions(typingCallbacks?: InlineTypingCallbacks) {
  if (!typingCallbacks) {
    return {}
  }
  return {
    typingCallbacks,
    onReplyStart: typingCallbacks.onReplyStart,
    ...(typingCallbacks.onIdle ? { onIdle: typingCallbacks.onIdle } : {}),
    ...(typingCallbacks.onCleanup ? { onCleanup: typingCallbacks.onCleanup } : {}),
  }
}

export async function sendInlineTypingToChats(params: {
  client: Pick<InlineSdkClient, "invokeRaw">
  chatIds: bigint[]
  typing: boolean
  onPartialError?: (chatId: bigint, error: unknown) => void
}): Promise<void> {
  if (params.chatIds.length === 0) return

  const failures: Array<{ chatId: bigint; error: unknown }> = []
  await Promise.all(
    params.chatIds.map(async (chatId) => {
      try {
        await sendInlineWorkingAction(params.client, { chatId, working: params.typing })
      } catch (error) {
        failures.push({ chatId, error })
      }
    }),
  )
  if (failures.length === 0) return
  if (failures.length === params.chatIds.length) {
    throw failures[0]?.error ?? new Error("inline typing failed")
  }
  for (const failure of failures) {
    params.onPartialError?.(failure.chatId, failure.error)
  }
}

function inlineBotPresenceStateKind(kind: InlineBotPresenceKind): BotPresenceState_Kind {
  switch (kind) {
    case "idle":
      return BotPresenceState_Kind.IDLE
    case "happy":
      return BotPresenceState_Kind.HAPPY
    case "waving":
      return BotPresenceState_Kind.WAVING
    case "jumping":
      return BotPresenceState_Kind.JUMPING
    case "failed":
      return BotPresenceState_Kind.FAILED
    case "waiting":
      return BotPresenceState_Kind.WAITING
    case "running":
      return BotPresenceState_Kind.RUNNING
    case "review":
      return BotPresenceState_Kind.REVIEW
  }
}

function normalizeInlineBotPresenceKind(value: unknown): InlineBotPresenceKind | undefined {
  if (typeof value !== "string") return undefined
  switch (value.trim().toLowerCase()) {
    case "idle":
    case "happy":
    case "waving":
    case "jumping":
    case "failed":
    case "waiting":
    case "running":
    case "review":
      return value.trim().toLowerCase() as InlineBotPresenceKind
    default:
      return undefined
  }
}

function normalizeInlineBotPresenceComment(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined
  const text = value.replace(/\s+/g, " ").trim()
  if (!text) return undefined
  return Array.from(text).slice(0, INLINE_BOT_PRESENCE_COMMENT_MAX_LENGTH).join("")
}

export function resolveInlineBotPresenceSignal(payload: InlineReplyPayload): InlineBotPresenceSignal | null {
  const channelData = isRecord(payload.channelData) ? payload.channelData : undefined
  const inlineData = channelData && isRecord(channelData.inline) ? channelData.inline : undefined
  const rawPresence = inlineData && isRecord(inlineData.botPresence) ? inlineData.botPresence : undefined
  if (!rawPresence) return null

  const kind = normalizeInlineBotPresenceKind(rawPresence.kind) ?? "happy"
  const comment = normalizeInlineBotPresenceComment(rawPresence.comment)
  return comment ? { kind, comment } : { kind }
}

async function sendInlineBotPresenceToChats(params: {
  client: Pick<InlineSdkClient, "invokeRaw">
  chatIds: bigint[]
  kind: InlineBotPresenceKind
  comment?: string
  onPartialError?: (chatId: bigint, error: unknown) => void
}): Promise<void> {
  if (params.chatIds.length === 0) return

  const failures: Array<{ chatId: bigint; error: unknown }> = []
  await Promise.all(
    params.chatIds.map(async (chatId) => {
      try {
        await params.client.invokeRaw(Method.SET_BOT_PRESENCE_STATE, {
          oneofKind: "setBotPresenceState",
          setBotPresenceState: {
            peerId: {
              type: {
                oneofKind: "chat",
                chat: { chatId },
              },
            },
            state: {
              kind: inlineBotPresenceStateKind(params.kind),
              ...(params.comment ? { comment: params.comment } : {}),
            },
          },
        })
      } catch (error) {
        failures.push({ chatId, error })
      }
    }),
  )
  if (failures.length === 0) return
  if (failures.length === params.chatIds.length) {
    throw failures[0]?.error ?? new Error("inline bot presence failed")
  }
  for (const failure of failures) {
    params.onPartialError?.(failure.chatId, failure.error)
  }
}

export async function sendInlineTypingAndBotPresenceToChats(params: {
  client: Pick<InlineSdkClient, "invokeRaw">
  chatIds: bigint[]
  typing: boolean
  presenceKind: InlineBotPresenceKind
  onTypingPartialError?: (chatId: bigint, error: unknown) => void
  onPresencePartialError?: (chatId: bigint, error: unknown) => void
  onPresenceError?: (error: unknown) => void
}): Promise<void> {
  let typingError: unknown = null
  await Promise.all([
    sendInlineTypingToChats({
      client: params.client,
      chatIds: params.chatIds,
      typing: params.typing,
      ...(params.onTypingPartialError ? { onPartialError: params.onTypingPartialError } : {}),
    }).catch((error) => {
      typingError = error
    }),
    sendInlineBotPresenceToChats({
      client: params.client,
      chatIds: params.chatIds,
      kind: params.presenceKind,
      ...(params.onPresencePartialError ? { onPartialError: params.onPresencePartialError } : {}),
    }).catch((error) => {
      params.onPresenceError?.(error)
    }),
  ])

  if (typingError != null) {
    throw typingError
  }
}

export function createInlineBotPresenceLifecycle(params: {
  client: Pick<InlineSdkClient, "invokeRaw">
  chatIds: bigint[]
  onPartialError: (chatId: bigint, error: unknown) => void
  onError: (error: unknown) => void
}) {
  let active = false
  let finishing = false
  let idleTimer: ReturnType<typeof setTimeout> | undefined
  let gestureTimer: ReturnType<typeof setTimeout> | undefined
  let currentKind: InlineBotPresenceKind | undefined
  let currentComment: string | undefined
  let busyKind: InlineBotPresenceKind = "running"
  let busyComment: string | undefined
  let sendChain: Promise<void> = Promise.resolve()
  let generation = 0

  const clearIdleTimer = () => {
    if (!idleTimer) return
    clearTimeout(idleTimer)
    idleTimer = undefined
  }

  const clearGestureTimer = () => {
    if (!gestureTimer) return
    clearTimeout(gestureTimer)
    gestureTimer = undefined
  }

  const send = (kind: InlineBotPresenceKind, comment?: string): Promise<void> => {
    if (currentKind === kind && currentComment === comment) return Promise.resolve()
    const chatIds = params.chatIds
    currentKind = kind
    currentComment = comment
    sendChain = sendChain
      .catch(() => {})
      .then(() =>
        sendInlineBotPresenceToChats({
          client: params.client,
          chatIds,
          kind,
          ...(comment ? { comment } : {}),
          onPartialError: params.onPartialError,
        }).catch(params.onError),
      )
    return sendChain
  }

  const scheduleIdle = (
    delayMs = INLINE_BOT_PRESENCE_IDLE_DELAY_MS,
    expectedGeneration = generation,
  ) => {
    clearIdleTimer()
    idleTimer = setTimeout(() => {
      idleTimer = undefined
      if (generation !== expectedGeneration) return
      active = false
      finishing = false
      busyKind = "running"
      busyComment = undefined
      void send("idle")
    }, delayMs)
    idleTimer.unref?.()
  }

  const showBusy = async (kind: InlineBotPresenceKind, comment?: string): Promise<void> => {
    if (!active || finishing) return
    clearIdleTimer()
    clearGestureTimer()
    busyKind = kind
    busyComment = comment
    await send(kind, comment)
  }

  const gesture = (
    kind: InlineBotPresenceKind,
    resumeKind = busyKind,
    comment?: string,
    resumeComment = busyComment,
  ) => {
    if (params.chatIds.length === 0) return
    clearIdleTimer()
    clearGestureTimer()
    active = true
    const expectedGeneration = generation
    void send(kind, comment)
    gestureTimer = setTimeout(() => {
      gestureTimer = undefined
      if (generation !== expectedGeneration) return
      if (!active || finishing) return
      void send(resumeKind, resumeComment)
    }, INLINE_BOT_PRESENCE_GESTURE_MS)
    gestureTimer.unref?.()
  }

  return {
    retarget: async (chatId: bigint) => {
      generation += 1
      clearIdleTimer()
      clearGestureTimer()
      const oldChatIds = params.chatIds
      params.chatIds = [chatId]
      // Adoption means work continues in the child even if a parent gesture was
      // finishing. Start a fresh lifecycle so the child cannot remain busy.
      active = true
      finishing = false
      currentKind = undefined
      currentComment = undefined
      sendChain = sendChain.catch(() => {}).then(() => sendInlineBotPresenceToChats({
        client: params.client,
        chatIds: oldChatIds,
        kind: "idle",
        onPartialError: params.onPartialError,
      }).catch(params.onError))
      await send(busyKind, busyComment)
    },
    start: async (cue?: InlineBotPresenceSignal | null) => {
      if (params.chatIds.length === 0) return
      clearIdleTimer()
      if (active && !finishing) return
      active = true
      finishing = false
      const cueKind = cue?.kind
      busyKind = cueKind === "review" ? "review" : "running"
      busyComment = undefined
      if (cueKind === "waving") {
        gesture("waving", busyKind)
        return
      }
      await send(busyKind, busyComment)
    },
    busy: (kind: InlineBotPresenceKind, comment?: string) => {
      void showBusy(kind, comment)
    },
    gesture: (kind: InlineBotPresenceKind, comment?: string) => {
      gesture(kind, busyKind, comment)
    },
    express: (signal: InlineBotPresenceSignal) => {
      if (signal.kind === "failed") {
        if (params.chatIds.length === 0) return
        clearIdleTimer()
        clearGestureTimer()
        active = true
        finishing = true
        const expectedGeneration = generation
        void send("failed", signal.comment).finally(() => {
          if (generation === expectedGeneration) {
            scheduleIdle(INLINE_BOT_PRESENCE_FAILED_MS, expectedGeneration)
          }
        })
        return
      }
      if (params.chatIds.length === 0) return
      clearIdleTimer()
      clearGestureTimer()
      active = true
      finishing = true
      const expectedGeneration = generation
      void send(signal.kind, signal.comment).finally(() => {
        if (generation === expectedGeneration) scheduleIdle(undefined, expectedGeneration)
      })
    },
    finish: () => {
      if (!active || finishing) return
      finishing = true
      clearGestureTimer()
      scheduleIdle(INLINE_BOT_PRESENCE_FINISH_IDLE_DELAY_MS)
    },
    fail: (comment?: string) => {
      if (params.chatIds.length === 0) return
      clearIdleTimer()
      clearGestureTimer()
      active = true
      finishing = true
      const expectedGeneration = generation
      void send("failed", comment).finally(() => {
        if (generation === expectedGeneration) {
          scheduleIdle(INLINE_BOT_PRESENCE_FAILED_MS, expectedGeneration)
        }
      })
    },
    cleanup: () => {
      if (!active) return
      if (finishing) return
      clearIdleTimer()
      clearGestureTimer()
      active = false
      const expectedGeneration = generation
      void send("idle").finally(() => {
        if (generation !== expectedGeneration) return
        finishing = false
        busyKind = "running"
        busyComment = undefined
      })
    },
  }
}
