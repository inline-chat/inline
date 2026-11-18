/**
 * The demo control channel: plain, structured-cloneable data between a UI
 * context and the demo world in the core's worker. It travels beside the
 * core protocol (on its own `BroadcastChannel`), never inside it.
 *
 * Every command may carry an `id`; the world answers each one with a
 * `result` naming it, and broadcasts `status` after every change. IDs are
 * decimal strings, as in `@inline/core-protocol`. Commands and events share
 * the channel, so no command kind is also an event kind (`status`,
 * `result`); each side ignores what is not for it.
 *
 * This file has no imports, so the UI can import it without pulling in the
 * server model.
 */

export type DemoStorageKind = "opfs" | "memory"

export type DemoOtherUserAction = "read" | "react" | "edit" | "delete" | "pin" | "unpin"

/** What a delivered message carries. */
export type DemoDeliverContent =
  | "text"
  | "photo"
  | "tallPhoto"
  | "widePhoto"
  | "squarePhoto"
  | "video"
  | "document"
  | "voice"
  | "entities"
  | "mention"
  | "code"
  | "emoji"
  | "rtl"
  | "long"
  | "reply"
  | "forward"
  | "blocks"
  | "buttons"
  | "form"

export const DEMO_DELIVER_CONTENT: readonly DemoDeliverContent[] = [
  "text",
  "photo",
  "tallPhoto",
  "widePhoto",
  "squarePhoto",
  "video",
  "document",
  "voice",
  "entities",
  "mention",
  "code",
  "emoji",
  "rtl",
  "long",
  "reply",
  "forward",
  "blocks",
  "buttons",
  "form",
]

/** Compose actions other members can show (`UpdateComposeAction`). */
export type DemoComposeActionName =
  | "typing"
  | "uploadingPhoto"
  | "uploadingDocument"
  | "uploadingVideo"
  | "recordingVoice"
  | "working"

const COMPOSE_NAMES: readonly string[] = [
  "typing",
  "uploadingPhoto",
  "uploadingDocument",
  "uploadingVideo",
  "recordingVoice",
  "working",
]

/**
 * Background activity: other members typing now and then in recent chats
 * (`low`, `normal`), and at `busy` also messages and reactions. Each scale
 * has a preset (`DEMO_ACTIVITY_PRESETS`); `off` for measurements.
 */
export type DemoActivityLevel = "off" | "low" | "normal" | "busy"

export const DEMO_ACTIVITY_PRESETS: Record<"small" | "medium" | "large", DemoActivityLevel> = {
  small: "low",
  medium: "normal",
  large: "normal",
}

/** The account's other device changes a dialog (user-bucket records, as from another session). */
export type DemoOtherDeviceAction =
  | "pin"
  | "unpin"
  | "archive"
  | "unarchive"
  | "markUnread"
  | "mute"
  | "mentionsOnly"
  | "unmute"
  | "open"
  | "close"

const OTHER_DEVICE_ACTIONS: readonly string[] = [
  "pin",
  "unpin",
  "archive",
  "unarchive",
  "markUnread",
  "mute",
  "mentionsOnly",
  "unmute",
  "open",
  "close",
]

export type DemoCommand = { id?: number } & (
  /** Ask the world to broadcast its status now. */
  | { kind: "requestStatus" }
  /**
   * One incoming message now. Defaults: a recent inbox chat, a member, a text
   * in the chat's voice. `content` picks what it carries (media of a shape,
   * entities, a mention of the account, a code block, emoji only, right to
   * left, long, a reply, a forward, or the agent's blocks, buttons or form).
   */
  | { kind: "deliver"; chatId?: string; text?: string; fromId?: string; content?: DemoDeliverContent }
  /** Incoming messages at a steady rate, into one chat or spread over recent ones. */
  | { kind: "stream"; action: "start"; ratePerSecond: number; chatId?: string }
  | { kind: "stream"; action: "stop" }
  /**
   * An agent posts a message and edits it in place `updatesPerSecond` times a
   * second (20 to 60) for `durationMs`, growing its text, as streamed answers do.
   */
  | { kind: "agent"; action: "start"; chatId?: string; updatesPerSecond?: number; durationMs?: number }
  | { kind: "agent"; action: "stop" }
  /** Offline: the server refuses connections and drops the live one. Online: it accepts again. */
  | { kind: "network"; online: boolean }
  /** Delay (ms) and loss (0 to 1) applied to every RPC acknowledgement and result. */
  | { kind: "faults"; latencyMs: number; lossRate: number }
  /**
   * Another member acts in a chat. `read` is the account's other device
   * reading the chat (the protocol has no read receipts from other users);
   * `react` and `pin` target `messageId` or the latest message; `edit`,
   * `delete` and `unpin` target `messageId` or the latest message from
   * someone else (`unpin`: the latest pinned one).
   */
  | {
      kind: "otherUser"
      action: DemoOtherUserAction
      chatId: string
      messageId?: string
      emoji?: string
      text?: string
    }
  /**
   * A member shows a compose action in a chat for `ms` (default 4,000, at
   * most 60,000), refreshed every 3 s as clients do, then stops. `stop`
   * ends it now. Defaults: a recent chat, one of its members, `typing`.
   */
  | {
      kind: "typing"
      chatId?: string
      userId?: string
      ms?: number
      action?: DemoComposeActionName | "stop"
    }
  /** Background activity level (see `DemoActivityLevel`). */
  | { kind: "activity"; level: DemoActivityLevel }
  /**
   * Media transfers: delay (ms) added to upload results (default 250) and to
   * file parts (default 0), finishes that answer `processing` first, the
   * next finishes failing (retryable), and whether a one-part file may ride
   * inside its create call (default off, so every upload shows progress).
   */
  | {
      kind: "media"
      uploadLatencyMs?: number
      downloadLatencyMs?: number
      processingRounds?: number
      failNext?: number
      inlineData?: boolean
    }
  /** Bot buttons and forms: fail the next N, fail a share at random, the bot's answer delay. */
  | { kind: "actions"; failNext?: number; failureRate?: number; answerDelayMs?: number }
  /** A member adds or removes someone in a private thread. Default user: a space member outside it (add), a member (remove). */
  | { kind: "participants"; action: "add" | "remove"; chatId: string; userId?: string }
  /** The account's other device pins, archives, marks unread, mutes or opens a chat. */
  | { kind: "otherDevice"; action: DemoOtherDeviceAction; chatId: string }
  /** Forget the simulated server's saved state. The replica is erased by signing out. */
  | { kind: "resetServer" }
)

export type DemoStatus = {
  kind: "status"
  /** Seeding is done and the server accepts connections (unless offline). */
  ready: boolean
  scale: string
  seed: number
  storage: DemoStorageKind
  /** Where the simulated server keeps its state across reloads. */
  serverPersistence: "opfs" | "memory" | "unavailable"
  chats: number
  messages: number
  /** Chats whose every message is in memory. */
  materializedChats: number
  timings: { planMs?: number; seedMs?: number; restoreMs?: number }
  online: boolean
  latencyMs: number
  lossRate: number
  connection: "idle" | "connecting" | "connected" | "dead"
  stream?: { ratePerSecond: number; chatId?: string; delivered: number }
  agent?: {
    chatId: string
    messageId: string
    updatesPerSecond: number
    edits: number
    running: boolean
  }
  /** Chats the controls default to: the most recent inbox chats. */
  recentChatIds: string[]
  activity: DemoActivityLevel
  /** Compose actions other members show now. */
  typing: Array<{ chatId: string; userId: string; action: DemoComposeActionName }>
  media: {
    uploadLatencyMs: number
    downloadLatencyMs: number
    processingRounds: number
    failNext: number
    inlineData: boolean
    uploadsCompleted: number
    partsServed: number
  }
  actions: { failNext: number; failureRate: number; answerDelayMs: number }
  /** The account's latest compose action as the server saw it (`SEND_COMPOSE_ACTION`). */
  ownCompose?: { chatId: string; action: number }
  /** Where to find each kind of content, for scripted checks. */
  samples: DemoSamples
  lastEvent?: string
  error?: string
}

export type DemoSampleMessage = { chatId: string; messageId: string }

export type DemoSamples = {
  photo?: DemoSampleMessage
  tallPhoto?: DemoSampleMessage
  widePhoto?: DemoSampleMessage
  video?: DemoSampleMessage
  document?: DemoSampleMessage
  voice?: DemoSampleMessage
  entities?: DemoSampleMessage
  forward?: DemoSampleMessage
  buttons?: DemoSampleMessage
  form?: DemoSampleMessage
  blocks?: DemoSampleMessage
  directChatId?: string
  publicThreadId?: string
  /** A private thread, and a member of its space who is not in it. */
  privateThread?: { chatId: string; outsiderUserId?: string }
  /** A word that appears in older messages of a chat (server search beyond the local window). */
  search?: { chatId: string; query: string; messageId: string }
}

export type DemoResult = {
  kind: "result"
  id?: number
  ok: boolean
  error?: string
  /** What the command did, for example the message it created. */
  detail?: { chatId?: string; messageId?: string; userId?: string }
}

export type DemoEvent = DemoStatus | DemoResult

export type DemoConfig = {
  scale: "small" | "medium" | "large"
  seed: number
  storage: DemoStorageKind
}

/** Read a config from untrusted input (a worker name, a URL); defaults fill gaps. */
export const parseDemoConfig = (value: unknown, defaults: DemoConfig = DEFAULT_DEMO_CONFIG): DemoConfig => {
  let input: unknown = value
  if (typeof value === "string") {
    try {
      input = JSON.parse(value)
    } catch {
      input = undefined
    }
  }
  const record = isRecord(input) ? input : {}
  const scale = record.scale
  const seed = typeof record.seed === "string" ? Number(record.seed) : record.seed
  const storage = record.storage
  return {
    scale: scale === "small" || scale === "medium" || scale === "large" ? scale : defaults.scale,
    seed: typeof seed === "number" && Number.isSafeInteger(seed) && seed >= 0 ? seed >>> 0 : defaults.seed,
    storage: storage === "opfs" || storage === "memory" ? storage : defaults.storage,
  }
}

export const DEFAULT_DEMO_CONFIG: DemoConfig = { scale: "medium", seed: 1, storage: "opfs" }

/** The demo's fixed user. */
export const DEMO_USER_ID = "1"

/** Names that keep a demo apart from real accounts and from other demos. */
export const demoNames = (config: DemoConfig) => {
  const key = `${config.scale}-${config.seed}-${config.storage}`
  return {
    /** The link account origin (locks and channels are keyed by it). */
    origin: `inline-demo://${key}`,
    /** The OPFS namespace of the replica and of the server's saved state. */
    namespace: `demo-${key}`,
    /** The control channel. */
    channel: `inline-demo/v1/${key}/control`,
  }
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null

const isId = (value: unknown): value is string => typeof value === "string" && /^[1-9]\d{0,18}$/.test(value)
const isOptionalId = (value: unknown) => value === undefined || isId(value)
const isOptionalNumber = (value: unknown) => value === undefined || (typeof value === "number" && Number.isFinite(value))

/** Validate a command that arrived over the channel. */
export const isDemoCommand = (value: unknown): value is DemoCommand => {
  if (!isRecord(value) || typeof value.kind !== "string") return false
  if (value.id !== undefined && typeof value.id !== "number") return false
  switch (value.kind) {
    case "requestStatus":
    case "resetServer":
      return true
    case "deliver":
      return (
        isOptionalId(value.chatId) &&
        isOptionalId(value.fromId) &&
        (value.text === undefined || typeof value.text === "string") &&
        (value.content === undefined || DEMO_DELIVER_CONTENT.includes(value.content as DemoDeliverContent))
      )
    case "typing":
      return (
        isOptionalId(value.chatId) &&
        isOptionalId(value.userId) &&
        isOptionalNumber(value.ms) &&
        (value.action === undefined || value.action === "stop" || COMPOSE_NAMES.includes(value.action as string))
      )
    case "activity":
      return value.level === "off" || value.level === "low" || value.level === "normal" || value.level === "busy"
    case "media":
      return (
        isOptionalNumber(value.uploadLatencyMs) &&
        isOptionalNumber(value.downloadLatencyMs) &&
        isOptionalNumber(value.processingRounds) &&
        isOptionalNumber(value.failNext) &&
        (value.inlineData === undefined || typeof value.inlineData === "boolean")
      )
    case "actions":
      return isOptionalNumber(value.failNext) && isOptionalNumber(value.failureRate) && isOptionalNumber(value.answerDelayMs)
    case "participants":
      return (value.action === "add" || value.action === "remove") && isId(value.chatId) && isOptionalId(value.userId)
    case "otherDevice":
      return OTHER_DEVICE_ACTIONS.includes(value.action as string) && isId(value.chatId)
    case "stream":
      return value.action === "stop" ||
        (value.action === "start" &&
          typeof value.ratePerSecond === "number" &&
          Number.isFinite(value.ratePerSecond) &&
          isOptionalId(value.chatId))
    case "agent":
      return value.action === "stop" ||
        (value.action === "start" &&
          isOptionalId(value.chatId) &&
          (value.updatesPerSecond === undefined || typeof value.updatesPerSecond === "number") &&
          (value.durationMs === undefined || typeof value.durationMs === "number"))
    case "network":
      return typeof value.online === "boolean"
    case "faults":
      return (
        typeof value.latencyMs === "number" &&
        Number.isFinite(value.latencyMs) &&
        typeof value.lossRate === "number" &&
        Number.isFinite(value.lossRate)
      )
    case "otherUser":
      return (
        (value.action === "read" ||
          value.action === "react" ||
          value.action === "edit" ||
          value.action === "delete" ||
          value.action === "pin" ||
          value.action === "unpin") &&
        isId(value.chatId) &&
        isOptionalId(value.messageId) &&
        (value.emoji === undefined || typeof value.emoji === "string") &&
        (value.text === undefined || typeof value.text === "string")
      )
    default:
      return false
  }
}

export const isDemoEvent = (value: unknown): value is DemoEvent =>
  isRecord(value) && (value.kind === "status" || value.kind === "result")
