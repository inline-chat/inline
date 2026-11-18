import { DialogNotificationSettings_Mode, MessageEntity_Type } from "@inline-chat/protocol/core"
import { Log } from "@inline/log"
import { createDemoAccount, isDemoScale, type DemoAccount, type DemoChatPlan, type DemoScale } from "./demo-account"
import {
  botMessage,
  emojiOnly,
  extrasOf,
  mediaKindOf,
  mediaSpec,
  withEntities,
  type DemoExtras,
  type DemoPhotoShape,
} from "./demo-content"
import {
  DEMO_ACTIVITY_PRESETS,
  type DemoActivityLevel,
  type DemoCommand,
  type DemoComposeActionName,
  type DemoDeliverContent,
  type DemoEvent,
  type DemoResult,
  type DemoSamples,
  type DemoStatus,
  type DemoStorageKind,
} from "./demo-protocol"
import {
  DemoServerModel,
  isDemoPersistedState,
  type DemoDialogOverrides,
  type DemoPersistedState,
} from "./demo-server-model"
import { realTurn } from "./event-loop"
import { SeededRandom } from "./rng"
import { ScriptedTransport } from "./scripted-transport"
import { ModelServerEndpoint, type FrameDecision, type OutgoingFrame } from "./server-model"

/**
 * The simulated world behind the demo account: a `DemoServerModel` seeded
 * with a `DemoAccount`, wired to a `ScriptedTransport` through a
 * `ModelServerEndpoint`. The core's realtime client uses `transport` as its
 * transport and cannot tell it from a socket to the server.
 *
 * - Seeding is chunked (`chunkSize` chats per event-loop turn) and lazy (no
 *   message exists until something reads it), so the worker stays
 *   responsive. Connections wait until seeding is done.
 * - `handle(command)` runs one control command (see `demo-protocol.ts`):
 *   incoming messages with any content, message streams, a streaming agent,
 *   offline and back, latency and loss on acknowledgements, other members'
 *   reactions, edits, deletes, pins and typing, participants added and
 *   removed, the account's other device changing dialogs, media transfer
 *   latency and failures, bot answer failures, background activity.
 * - With a `store`, the server's changes survive a reload: saved within a
 *   second (the user bucket at once) and restored at start.
 * - `onEvent` receives `status` after every change (at most four a second
 *   while a stream runs).
 */

export type DemoWorldStore = {
  kind: "opfs" | "memory"
  load(): Promise<unknown>
  save(state: DemoPersistedState): Promise<void>
  erase(): Promise<void>
}

/** A store that keeps the state in memory (tests; the "memory" demo). */
export const memoryWorldStore = (): DemoWorldStore & { saved: DemoPersistedState | undefined } => {
  const store = {
    kind: "memory" as const,
    saved: undefined as DemoPersistedState | undefined,
    load: async () => (store.saved ? structuredClone(store.saved) : undefined),
    save: async (state: DemoPersistedState) => {
      store.saved = structuredClone(state)
    },
    erase: async () => {
      store.saved = undefined
    },
  }
  return store
}

export type DemoWorldOptions = {
  seed: number
  scale: DemoScale
  storage: DemoStorageKind
  /** Where the server's own state lives. Without one nothing is kept. */
  store?: DemoWorldStore
  /** Milliseconds since the epoch. Default `Date.now`. */
  now?: () => number
  logger?: Log
  onEvent?: (event: DemoEvent) => void
  /** Asked when the server comes back online, so the client retries at once. */
  onWake?: () => void
  /** Chats installed per event-loop turn while seeding. Default 500. */
  chunkSize?: number
  /** Background activity at start; `preset` takes the scale's. Default `off`. */
  activity?: DemoActivityLevel | "preset"
}

const SAVE_DELAY_MS = 1_000
const STATUS_INTERVAL_MS = 250
const HOUSEKEEPING_MS = 5_000
/** Journal records kept per bucket; older ones are pruned, as retention does. */
const JOURNAL_KEEP = 5_000
const AGENT_EMOJI = ["👍", "🎉", "👀", "🔥", "✅", "🙏", "😂", "❤️"]
/** Compose actions are refreshed this often while they last, as clients do. */
const COMPOSE_REFRESH_MS = 3_000
const ACTIVITY_TICK_MS = 1_000
/** Chance per tick that someone starts typing somewhere, by level. */
const ACTIVITY_RATE: Record<DemoActivityLevel, number> = { off: 0, low: 0.08, normal: 0.25, busy: 0.6 }
const SAMPLES_DELAY_MS = 1_500
const RTL_TEXTS = [
  "مرحبا بالجميع، الإصدار جاهز للمراجعة غدا",
  "שלום לכולם, הגרסה מוכנה לבדיקה מחר",
  "تم نشر build 4512 على staging ✅",
  "הלקוח אישר את ה-design החדש 🎉 נמשיך ב-review מחר",
  "ملاحظات الاجتماع: latency أفضل بعد migration",
]

const clamp = (value: number, min: number, max: number) => Math.min(max, Math.max(min, value))

export class DemoWorld {
  readonly transport = new ScriptedTransport({ connectPolicy: "manual" })
  /** Resolves when seeding is done (or failed; see `status().error`). */
  readonly ready: Promise<void>
  private account: DemoAccount | undefined
  private model: DemoServerModel | undefined
  private endpoint: ModelServerEndpoint | undefined
  private readonly log: Log
  private readonly now: () => number
  private readonly random: SeededRandom
  private isReady = false
  private disposed = false
  private online = true
  private latencyMs = 0
  private lossRate = 0
  private persistence: DemoStatus["serverPersistence"]
  private timings: DemoStatus["timings"] = {}
  private error: string | undefined
  private lastEvent: string | undefined
  private recent: bigint[] = []
  private activityLevel: DemoActivityLevel
  private activityTimer: ReturnType<typeof setInterval> | undefined
  private readonly typing = new Map<
    string,
    { chatId: bigint; userId: bigint; action: DemoComposeActionName; endsAt: number; timer: ReturnType<typeof setInterval> }
  >()
  private readonly timers = new Set<ReturnType<typeof setTimeout>>()
  private uploadLatencyMs = 250
  private downloadLatencyMs = 0
  private sampled: DemoSamples | undefined

  private stream:
    | { ratePerSecond: number; chatId?: bigint; delivered: number; timer: ReturnType<typeof setInterval>; due: number }
    | undefined
  private agent:
    | {
        chatId: bigint
        messageId: bigint
        updatesPerSecond: number
        edits: number
        running: boolean
        text: string
        tokens: string[]
        endsAt: number
        timer?: ReturnType<typeof setInterval>
      }
    | undefined

  private saveTimer: ReturnType<typeof setTimeout> | undefined
  private saveDirty = false
  private saving: Promise<void> = Promise.resolve()
  private statusTimer: ReturnType<typeof setTimeout> | undefined
  private housekeeping: ReturnType<typeof setInterval> | undefined
  private lastStatus = ""
  private forgetful = false

  constructor(private readonly options: DemoWorldOptions) {
    if (!isDemoScale(options.scale)) throw new RangeError(`Unknown demo scale ${String(options.scale)}`)
    this.log = (options.logger ?? new Log("Demo")).withScope("World")
    this.now = options.now ?? Date.now
    this.random = new SeededRandom(options.seed).fork("demo-world")
    this.persistence = options.store?.kind ?? "memory"
    this.activityLevel = options.activity === "preset" ? DEMO_ACTIVITY_PRESETS[options.scale] : (options.activity ?? "off")
    this.ready = this.seed().catch((error: unknown) => {
      this.error = `Seeding failed: ${error instanceof Error ? error.message : String(error)}`
      this.log.error("seed.failed", { error })
      this.emitStatus()
    })
  }

  /** The server model, once seeded. */
  get server(): DemoServerModel | undefined {
    return this.model
  }

  get demoAccount(): DemoAccount | undefined {
    return this.account
  }

  // ---- Seeding ----------------------------------------------------------------

  private async seed() {
    const { seed, scale, store } = this.options
    let persisted: DemoPersistedState | undefined
    if (store) {
      try {
        const loaded = await store.load()
        if (isDemoPersistedState(loaded) && loaded.seed === seed && loaded.scale === scale) {
          persisted = loaded
        } else if (loaded != null) {
          this.log.warn("persisted.ignored", {})
        }
      } catch (error) {
        this.persistence = "unavailable"
        this.log.warn("persisted.load.failed", { error })
      }
    }
    const nowSeconds = () => Math.floor(this.now() / 1_000)
    const anchor = persisted?.anchor ?? nowSeconds()

    let started = this.now()
    const account = createDemoAccount({ seed, scale, anchor })
    this.timings.planMs = this.now() - started
    if (this.disposed) return

    started = this.now()
    const model = new DemoServerModel(account, { now: nowSeconds })
    const chunk = Math.max(1, this.options.chunkSize ?? 500)
    for (let index = 0; index < account.chats.length; index += chunk) {
      for (const plan of account.chats.slice(index, index + chunk)) model.installChat(plan)
      await realTurn()
      if (this.disposed) return
    }
    this.timings.seedMs = this.now() - started

    if (persisted) {
      started = this.now()
      model.restore(persisted)
      this.timings.restoreMs = this.now() - started
    } else if (store) {
      // A kept replica may hold an earlier session the store has no record of.
      model.assumeUnknownPast()
    }

    this.account = account
    this.model = model
    this.recent = account.chats
      .filter((chat) => !chat.archived && (chat.open || chat.pinned))
      .sort(
        (left, right) =>
          Number(right.pinned) - Number(left.pinned) ||
          (left.pinnedOrder ?? left.order ?? "").localeCompare(right.pinnedOrder ?? right.order ?? ""),
      )
      .slice(0, 12)
      .map((chat) => chat.id)
    model.onChange = (change) => this.scheduleSave(change.kind === "user")
    model.schedule = (delayMs, run) => this.later(delayMs, run)
    const endpoint = new ModelServerEndpoint(model, this.transport)
    endpoint.interceptor = (frame) => this.intercept(frame)
    this.endpoint = endpoint
    this.isReady = true
    this.lastEvent = `Seeded ${account.chats.length} chats, ${account.totalMessages} messages`
    // Keep the anchor so dates do not move on the next load.
    if (!persisted) this.scheduleSave(true)
    this.housekeeping = setInterval(() => this.tidy(), HOUSEKEEPING_MS)
    this.setActivity(this.activityLevel)
    // Where each kind of content is, once the first sync is under way.
    this.later(SAMPLES_DELAY_MS, () => {
      this.samples()
      this.scheduleStatus()
    })
    await this.applyPolicy()
    this.emitStatus()
  }

  /** Run `run` after `delayMs` unless the world is disposed first. */
  private later(delayMs: number, run: () => void) {
    if (this.disposed) return
    const timer = setTimeout(() => {
      this.timers.delete(timer)
      if (this.disposed) return
      try {
        run()
      } catch (error) {
        this.log.warn("later.failed", { error })
      }
      this.scheduleStatus()
    }, delayMs)
    this.timers.add(timer)
  }

  // ---- Status -----------------------------------------------------------------

  status(): DemoStatus {
    const account = this.account
    return {
      kind: "status",
      ready: this.isReady,
      scale: this.options.scale,
      seed: this.options.seed,
      storage: this.options.storage,
      serverPersistence: this.persistence,
      chats: account?.chats.length ?? 0,
      messages: account?.totalMessages ?? 0,
      materializedChats: this.model?.materializedChats() ?? 0,
      timings: { ...this.timings },
      online: this.online,
      latencyMs: this.latencyMs,
      lossRate: this.lossRate,
      connection: this.transport.state,
      ...(this.stream
        ? {
            stream: {
              ratePerSecond: this.stream.ratePerSecond,
              ...(this.stream.chatId != null ? { chatId: this.stream.chatId.toString() } : {}),
              delivered: this.stream.delivered,
            },
          }
        : {}),
      ...(this.agent
        ? {
            agent: {
              chatId: this.agent.chatId.toString(),
              messageId: this.agent.messageId.toString(),
              updatesPerSecond: this.agent.updatesPerSecond,
              edits: this.agent.edits,
              running: this.agent.running,
            },
          }
        : {}),
      recentChatIds: this.recent.map(String),
      activity: this.activityLevel,
      typing: Array.from(this.typing.values(), (entry) => ({
        chatId: entry.chatId.toString(),
        userId: entry.userId.toString(),
        action: entry.action,
      })),
      media: {
        uploadLatencyMs: this.uploadLatencyMs,
        downloadLatencyMs: this.downloadLatencyMs,
        processingRounds: this.model?.transfers.settings.processingRounds ?? 0,
        failNext: this.model?.transfers.settings.failNext ?? 0,
        inlineData: this.model?.transfers.settings.inlineData ?? false,
        uploadsCompleted: this.model?.transfers.completed ?? 0,
        partsServed: this.model?.transfers.partsServed ?? 0,
      },
      actions: { ...(this.model?.actionSettings ?? { failNext: 0, failureRate: 0, answerDelayMs: 600 }) },
      ...(this.model?.ownCompose
        ? { ownCompose: { chatId: this.model.ownCompose.chatId, action: this.model.ownCompose.action } }
        : {}),
      samples: this.sampled ?? {},
      ...(this.lastEvent ? { lastEvent: this.lastEvent } : {}),
      ...(this.error ? { error: this.error } : {}),
    }
  }

  /** Send `status` now if it changed. */
  emitStatus() {
    if (this.statusTimer) {
      clearTimeout(this.statusTimer)
      this.statusTimer = undefined
    }
    const status = this.status()
    const serialized = JSON.stringify(status)
    if (serialized === this.lastStatus) return
    this.lastStatus = serialized
    this.options.onEvent?.(status)
  }

  private scheduleStatus() {
    if (this.statusTimer || this.disposed) return
    this.statusTimer = setTimeout(() => {
      this.statusTimer = undefined
      this.emitStatus()
    }, STATUS_INTERVAL_MS)
  }

  // ---- Commands ---------------------------------------------------------------

  /** Run one control command. Never throws; failures come back as data. */
  async handle(command: DemoCommand): Promise<DemoResult> {
    const id = command.id
    try {
      if (command.kind === "requestStatus") {
        this.lastStatus = ""
        this.emitStatus()
        return { kind: "result", ...(id != null ? { id } : {}), ok: true }
      }
      if (command.kind === "resetServer") {
        await this.resetServer()
        return this.done(id, "Server state forgotten")
      }
      await this.ready
      const model = this.model
      if (!model || !this.account) throw new Error(this.error ?? "The demo server is not ready")
      switch (command.kind) {
        case "deliver": {
          const chat = this.chat(command.chatId)
          const message = this.deliver(chat, command.text, command.fromId, command.content)
          return this.done(id, `Delivered message ${message.id} to chat ${chat.id}`, {
            chatId: chat.id.toString(),
            messageId: message.id.toString(),
          })
        }
        case "typing": {
          const entry = this.startTyping(command.chatId, command.userId, command.ms, command.action)
          return this.done(id, `${entry.action} in chat ${entry.chatId}`, {
            chatId: entry.chatId.toString(),
            userId: entry.userId.toString(),
          })
        }
        case "activity":
          this.setActivity(command.level)
          return this.done(id, `Background activity: ${command.level}`)
        case "media": {
          const settings = model.transfers.settings
          if (command.uploadLatencyMs != null) this.uploadLatencyMs = clamp(Math.round(command.uploadLatencyMs), 0, 30_000)
          if (command.downloadLatencyMs != null) {
            this.downloadLatencyMs = clamp(Math.round(command.downloadLatencyMs), 0, 30_000)
          }
          if (command.processingRounds != null) settings.processingRounds = clamp(Math.round(command.processingRounds), 0, 20)
          if (command.failNext != null) settings.failNext = clamp(Math.round(command.failNext), 0, 100)
          if (command.inlineData != null) settings.inlineData = command.inlineData
          return this.done(id, `Media: uploads +${this.uploadLatencyMs} ms, parts +${this.downloadLatencyMs} ms`)
        }
        case "actions": {
          const settings = model.actionSettings
          if (command.failNext != null) settings.failNext = clamp(Math.round(command.failNext), 0, 100)
          if (command.failureRate != null) settings.failureRate = clamp(command.failureRate, 0, 1)
          if (command.answerDelayMs != null) settings.answerDelayMs = clamp(Math.round(command.answerDelayMs), 0, 9_000)
          return this.done(id, `Bot actions: ${settings.failNext} to fail, ${Math.round(settings.failureRate * 100)}% failing`)
        }
        case "participants": {
          const detail = this.participants(command.action, command.chatId, command.userId)
          return this.done(id, `Participant ${command.action === "add" ? "added to" : "removed from"} chat ${command.chatId}`, detail)
        }
        case "otherDevice": {
          this.otherDevice(command.action, command.chatId)
          return this.done(id, `Other device: ${command.action} chat ${command.chatId}`, { chatId: command.chatId })
        }
        case "stream":
          if (command.action === "stop") {
            this.stopStream()
            return this.done(id, "Stream stopped")
          }
          this.startStream(command.ratePerSecond, command.chatId)
          return this.done(id, `Streaming ${this.stream?.ratePerSecond ?? 0} messages a second`)
        case "agent": {
          if (command.action === "stop") {
            this.stopAgent()
            return this.done(id, "Agent stopped")
          }
          const agent = this.startAgent(command.chatId, command.updatesPerSecond, command.durationMs)
          return this.done(id, `Agent streaming into chat ${agent.chatId}`, {
            chatId: agent.chatId.toString(),
            messageId: agent.messageId.toString(),
          })
        }
        case "network":
          await this.setOnline(command.online)
          return this.done(id, command.online ? "Server online" : "Server offline")
        case "faults":
          this.latencyMs = clamp(Math.round(command.latencyMs), 0, 30_000)
          this.lossRate = clamp(command.lossRate, 0, 1)
          return this.done(id, `Acknowledgements: ${this.latencyMs} ms, ${Math.round(this.lossRate * 100)}% lost`)
        case "otherUser": {
          const detail = this.otherUser(command)
          return this.done(id, `Other member: ${command.action} in chat ${command.chatId}`, detail)
        }
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      this.lastEvent = `Failed: ${message}`
      this.emitStatus()
      return { kind: "result", ...(id != null ? { id } : {}), ok: false, error: message }
    }
  }

  private done(id: number | undefined, event: string, detail?: DemoResult["detail"]): DemoResult {
    this.lastEvent = event
    this.emitStatus()
    return { kind: "result", ...(id != null ? { id } : {}), ok: true, ...(detail ? { detail } : {}) }
  }

  private requireModel() {
    if (!this.model || !this.account) throw new Error("The demo server is not ready")
    return { model: this.model, account: this.account }
  }

  private chat(chatId: string | bigint | undefined): DemoChatPlan {
    const { model } = this.requireModel()
    const id = chatId == null ? this.pickRecent() : BigInt(chatId)
    const plan = model.plan(id)
    if (!plan) throw new Error(`No chat ${id} in the demo account`)
    return plan
  }

  private pickRecent(): bigint {
    const candidates = this.recent.slice(0, 8)
    if (candidates.length === 0) {
      const first = this.account?.chats[0]
      if (!first) throw new Error("The demo account has no chats")
      return first.id
    }
    return this.random.pick(candidates)
  }

  private deliver(chat: DemoChatPlan, text?: string, fromId?: string, content: DemoDeliverContent = "text") {
    const { model, account } = this.requireModel()
    let from = fromId != null ? BigInt(fromId) : this.random.pick(chat.others)
    let body = text ?? account.textFor(chat, this.random)
    let extras: DemoExtras | undefined
    let replyToMsgId: bigint | undefined
    const photo = (shape: DemoPhotoShape) => {
      extras = { media: mediaSpec(this.random, "photo", shape) }
      if (text == null && this.random.bool(0.6)) body = ""
    }
    switch (content) {
      case "text":
        break
      case "photo":
        photo(this.random.pick(["landscape", "portrait", "wide"] as const))
        break
      case "tallPhoto":
        photo("tall")
        break
      case "widePhoto":
        photo("panorama")
        break
      case "squarePhoto":
        photo("square")
        break
      case "video":
      case "document":
      case "voice":
        extras = { media: mediaSpec(this.random, content) }
        if (text == null && (content === "voice" || this.random.bool(0.5))) body = ""
        break
      case "entities":
      case "code": {
        const mentionable = chat.others.flatMap((id) => {
          const user = account.user(id)
          return user ? [{ id, name: user.firstName }] : []
        })
        const rewritten = withEntities(this.random, body, mentionable, content === "code" ? 4 : undefined)
        body = rewritten.text
        extras = { entities: rewritten.entities }
        break
      }
      case "mention": {
        const mention = "@Demo"
        body = `${mention} ${body}`
        extras = {
          entities: [
            {
              type: MessageEntity_Type.MENTION,
              offset: 0n,
              length: BigInt(mention.length),
              entity: { oneofKind: "mention", mention: { userId: model.selfUserId } },
            },
          ],
        }
        break
      }
      case "emoji":
        body = emojiOnly(this.random)
        break
      case "rtl":
        body = text ?? this.random.pick(RTL_TEXTS)
        break
      case "long":
        body =
          text ??
          Array.from({ length: this.random.int(4, 7) }, () => account.textFor(chat, this.random)).join("\n\n")
        break
      case "reply":
        replyToMsgId = model.lazy(chat.id)?.latest()?.id
        break
      case "forward": {
        const source = account.chats.find((candidate) => candidate.id !== chat.id && candidate.count > 0)
        if (source) {
          const messageId = BigInt(this.random.int(1, source.count))
          const original = account.messageAt(source, messageId)
          body = text ?? original.text
          extras = {
            ...(extrasOf(original)?.media ? { media: extrasOf(original)!.media! } : {}),
            fwdFrom: {
              fromPeerId: { type: { oneofKind: "chat", chat: { chatId: source.id } } },
              fromId: original.fromId,
              fromMessageId: messageId,
            },
          }
        }
        break
      }
      case "blocks":
      case "buttons":
      case "form": {
        const bot = botMessage(content === "blocks" ? "summary" : content, this.random)
        body = bot.text
        extras = bot.extras
        if (fromId == null) from = account.agentUserId
        break
      }
    }
    return model.postWithContent({
      chatId: chat.id,
      fromId: from,
      text: body,
      ...(extras ? { extras } : {}),
      ...(replyToMsgId != null ? { replyToMsgId } : {}),
    })
  }

  // ---- Streams ----------------------------------------------------------------

  private startStream(ratePerSecond: number, chatId?: string) {
    this.stopStream()
    const rate = clamp(ratePerSecond, 0.1, 200)
    const chat = chatId != null ? this.chat(chatId).id : undefined
    const intervalMs = Math.max(16, 1_000 / rate)
    const perTick = (rate * intervalMs) / 1_000
    const stream = {
      ratePerSecond: rate,
      ...(chat != null ? { chatId: chat } : {}),
      delivered: 0,
      due: 0,
      timer: setInterval(() => {
        stream.due += perTick
        try {
          while (stream.due >= 1) {
            stream.due -= 1
            this.deliver(this.chat(stream.chatId))
            stream.delivered += 1
          }
        } catch (error) {
          this.log.warn("stream.failed", { error })
          this.stopStream()
        }
        this.scheduleStatus()
      }, intervalMs),
    }
    this.stream = stream
  }

  private stopStream() {
    if (!this.stream) return
    clearInterval(this.stream.timer)
    this.stream = undefined
  }

  private startAgent(chatId?: string, updatesPerSecond = 40, durationMs = 10_000) {
    this.stopAgent()
    const { model, account } = this.requireModel()
    const chat = this.chat(chatId)
    const rate = clamp(Math.round(updatesPerSecond), 20, 60)
    const tokens = account.textFor(chat, this.random).split(/\s+/).filter(Boolean)
    const first = tokens.shift() ?? "…"
    const message = model.postMessage({ chatId: chat.id, fromId: account.agentUserId, text: first })
    const agent: NonNullable<DemoWorld["agent"]> = {
      chatId: chat.id,
      messageId: message.id,
      updatesPerSecond: rate,
      edits: 0,
      running: true,
      text: first,
      tokens,
      endsAt: this.now() + clamp(durationMs, 500, 600_000),
    }
    agent.timer = setInterval(() => {
      if (this.now() >= agent.endsAt) {
        this.stopAgent()
        return
      }
      try {
        // One to three words per update, a paragraph now and then.
        for (let count = this.random.int(1, 3); count > 0; count -= 1) {
          if (agent.tokens.length === 0) {
            agent.tokens = account.textFor(chat, this.random).split(/\s+/).filter(Boolean)
            agent.text += this.random.bool(0.3) ? "\n\n" : " "
          } else {
            agent.text += " "
          }
          agent.text += agent.tokens.shift() ?? ""
        }
        model.editMessage(agent.chatId, agent.messageId, agent.text)
        agent.edits += 1
      } catch (error) {
        this.log.warn("agent.failed", { error })
        this.stopAgent()
      }
      this.scheduleStatus()
    }, 1_000 / rate)
    this.agent = agent
    return agent
  }

  private stopAgent() {
    const agent = this.agent
    if (!agent?.running) return
    if (agent.timer) clearInterval(agent.timer)
    agent.timer = undefined
    agent.running = false
    this.lastEvent = `Agent finished after ${agent.edits} edits`
    this.scheduleStatus()
  }

  // ---- Network ------------------------------------------------------------------

  private async setOnline(online: boolean) {
    this.online = online
    await this.applyPolicy()
    if (!online) {
      await this.transport.disconnect("demo-offline")
    } else {
      this.options.onWake?.()
    }
  }

  private async applyPolicy() {
    const transport = this.transport
    const policy = !this.isReady ? "manual" : this.online ? "accept" : "refuse"
    transport.connectPolicy = policy
    if (transport.state !== "connecting") return
    if (policy === "accept") await transport.accept()
    else if (policy === "refuse") await transport.refuse("demo-offline")
  }

  private intercept(frame: OutgoingFrame): FrameDecision {
    if (frame.kind !== "ack" && frame.kind !== "result") return "deliver"
    if (this.lossRate > 0 && this.random.next() < this.lossRate) return "drop"
    const body = frame.message.body
    const result = frame.kind === "result" && body.oneofKind === "rpcResult" ? body.rpcResult.result?.oneofKind : undefined
    const transfer =
      result === "getFilePart"
        ? this.downloadLatencyMs
        : result === "createUpload" || result === "saveUploadPart" || result === "finishUpload" || result === "getUploadState"
          ? this.uploadLatencyMs
          : 0
    const delay = this.latencyMs + transfer
    if (delay > 0) {
      this.transport.deliverAfter(delay, frame.message)
      return "drop"
    }
    return "deliver"
  }

  // ---- Other members --------------------------------------------------------------

  private otherUser(command: Extract<DemoCommand, { kind: "otherUser" }>): DemoResult["detail"] {
    const { model } = this.requireModel()
    const chat = this.chat(command.chatId)
    const messages = model.lazy(chat.id)
    if (!messages) throw new Error(`No chat ${chat.id}`)
    const chatId = chat.id.toString()
    if (command.action === "read") {
      const latest = messages.latest()
      if (!latest) throw new Error("The chat has no messages")
      model.readOnOtherDevice(chat.id, latest.id)
      return { chatId, messageId: latest.id.toString() }
    }
    const target =
      command.messageId != null
        ? BigInt(command.messageId)
        : command.action === "react" || command.action === "pin"
          ? messages.latest()?.id
          : command.action === "unpin"
            ? model.pinnedMessageIds(chat.id)[0]
            : messages
                .idsBefore(undefined, 200)
                .find((id) => messages.peek(id)?.fromId !== model.selfUserId)
    if (target == null || !messages.has(target)) throw new Error("No message to act on")
    const messageId = target.toString()
    switch (command.action) {
      case "react":
        model.addReaction(
          chat.id,
          target,
          this.random.pick(chat.others),
          command.emoji ?? this.random.pick(AGENT_EMOJI),
        )
        break
      case "edit": {
        const current = messages.get(target)?.text ?? ""
        model.editMessage(chat.id, target, command.text ?? `${current} (edited)`)
        break
      }
      case "delete":
        model.deleteMessages(chat.id, [target])
        break
      case "pin":
      case "unpin":
        model.setPinned(chat.id, target, command.action === "pin")
        break
    }
    return { chatId, messageId }
  }

  private participants(action: "add" | "remove", chatId: string, userId?: string): DemoResult["detail"] {
    const { model } = this.requireModel()
    const chat = this.chat(chatId)
    let user: bigint | undefined = userId != null ? BigInt(userId) : undefined
    if (user == null) {
      const inside = new Set(model.participantsOf(chat.id).map((entry) => entry.userId))
      user =
        action === "add"
          ? model.spaceMembersOf(chat.spaceId).find((id) => !inside.has(id))
          : Array.from(inside).find((id) => id !== model.selfUserId)
    }
    if (user == null) throw new Error(action === "add" ? "Everyone in the space is in this thread" : "Nobody to remove")
    if (action === "add") model.addParticipant(chat.id, user)
    else model.removeParticipant(chat.id, user)
    return { chatId, userId: user.toString() }
  }

  private otherDevice(action: string, chatId: string) {
    const { model } = this.requireModel()
    const chat = this.chat(chatId)
    const change: DemoDialogOverrides =
      action === "pin"
        ? { pinned: true, pinnedOrder: `!${this.now().toString(36)}` }
        : action === "unpin"
          ? { pinned: false, pinnedOrder: null }
          : action === "archive"
            ? { archived: true }
            : action === "unarchive"
              ? { archived: false }
              : action === "markUnread"
                ? { unreadMark: true }
                : action === "mute"
                  ? { notificationMode: DialogNotificationSettings_Mode.NONE }
                  : action === "mentionsOnly"
                    ? { notificationMode: DialogNotificationSettings_Mode.MENTIONS }
                    : action === "unmute"
                      ? { notificationMode: null }
                      : action === "open"
                        ? { open: true, archived: false }
                        : { open: false }
    model.updateDialog(chat.id, change)
  }

  // ---- Typing and background activity ----------------------------------------------

  private startTyping(chatId?: string, userId?: string, ms = 4_000, action: DemoComposeActionName | "stop" = "typing") {
    const { model } = this.requireModel()
    const chat = this.chat(chatId)
    const user = userId != null ? BigInt(userId) : this.random.pick(chat.others)
    const key = `${chat.id}:${user}`
    const existing = this.typing.get(key)
    if (existing) {
      clearInterval(existing.timer)
      this.typing.delete(key)
    }
    if (action === "stop") {
      model.composeAction(chat.id, user, null)
      this.scheduleStatus()
      return { chatId: chat.id, userId: user, action: "typing" as const }
    }
    const entry = {
      chatId: chat.id,
      userId: user,
      action,
      endsAt: this.now() + clamp(Math.round(ms), 200, 60_000),
      timer: setInterval(() => {
        if (this.now() >= entry.endsAt || this.disposed) {
          this.stopTyping(key)
          return
        }
        model.composeAction(chat.id, user, action)
      }, Math.min(COMPOSE_REFRESH_MS, Math.max(100, clamp(Math.round(ms), 200, 60_000)))),
    }
    this.typing.set(key, entry)
    model.composeAction(chat.id, user, action)
    this.scheduleStatus()
    return entry
  }

  private stopTyping(key: string) {
    const entry = this.typing.get(key)
    if (!entry) return
    clearInterval(entry.timer)
    this.typing.delete(key)
    if (!this.disposed) this.model?.composeAction(entry.chatId, entry.userId, null)
    this.scheduleStatus()
  }

  private setActivity(level: DemoActivityLevel) {
    this.activityLevel = level
    if (this.activityTimer) clearInterval(this.activityTimer)
    this.activityTimer = undefined
    if (level === "off" || this.disposed) return
    this.activityTimer = setInterval(() => this.activityTick(), ACTIVITY_TICK_MS)
  }

  private activityTick() {
    if (!this.model || this.disposed || !this.online) return
    const level = this.activityLevel
    if (this.random.next() >= ACTIVITY_RATE[level]) return
    try {
      const chat = this.chat(undefined)
      const userId = this.random.pick(chat.others)
      const ms = this.random.int(1_500, 6_000)
      const action: DemoComposeActionName = this.random.bool(0.85)
        ? "typing"
        : this.random.pick(["uploadingPhoto", "recordingVoice", "uploadingDocument"] as const)
      this.startTyping(chat.id.toString(), userId.toString(), ms, action)
      if (level === "busy" && this.random.bool(0.5)) {
        this.later(ms, () => {
          this.deliver(chat, undefined, userId.toString(), this.random.bool(0.2) ? "photo" : "text")
        })
      }
    } catch (error) {
      this.log.warn("activity.failed", { error })
    }
  }

  // ---- Samples ---------------------------------------------------------------------

  /** Where each kind of content is: recent chats first, then any. Computed once. */
  samples(): DemoSamples {
    if (this.sampled) return this.sampled
    const { model, account } = this.requireModel()
    const samples: DemoSamples = {}
    const recent = new Set(this.recent)
    const chats = [
      ...this.recent.flatMap((id) => (model.plan(id) ? [model.plan(id)!] : [])),
      ...account.chats.filter((chat) => !recent.has(chat.id) && !chat.archived && chat.open).slice(0, 30),
    ]
    const note = (key: keyof DemoSamples, chat: DemoChatPlan, id: bigint) => {
      if (samples[key] == null) (samples as Record<string, unknown>)[key] = { chatId: chat.id.toString(), messageId: id.toString() }
    }
    for (const chat of chats) {
      const messages = model.lazy(chat.id)
      if (!messages) continue
      for (const id of messages.idsBefore(undefined, 120)) {
        const message = messages.peek(id)
        const extras = extrasOf(message)
        if (!extras) continue
        const kind = mediaKindOf(extras)
        if (kind === "photo" && extras.media?.kind === "photo") {
          const { w, h } = extras.media
          note(h / w > 2 ? "tallPhoto" : w / h > 3 ? "widePhoto" : "photo", chat, id)
        } else if (kind) {
          note(kind, chat, id)
        }
        if (extras.entities) note("entities", chat, id)
        if (extras.fwdFrom) note("forward", chat, id)
        if (extras.actions) note("buttons", chat, id)
        else if (extras.blockContent?.blocks.some((block) => block.kind.oneofKind === "form")) note("form", chat, id)
        else if (extras.blockContent) note("blocks", chat, id)
      }
    }
    const inbox = account.chats.filter((chat) => chat.open && !chat.archived)
    const direct = inbox.find((chat) => chat.peerUserId != null) ?? account.chats.find((chat) => chat.peerUserId != null)
    if (direct) samples.directChatId = direct.id.toString()
    const isPublic = inbox.find((chat) => chat.isPublic === true) ?? account.chats.find((chat) => chat.isPublic === true)
    if (isPublic) samples.publicThreadId = isPublic.id.toString()
    const privateThread =
      inbox.find((chat) => chat.spaceId != null && chat.isPublic === false) ??
      account.chats.find((chat) => chat.spaceId != null && chat.isPublic === false)
    if (privateThread) {
      const inside = new Set(model.participantsOf(privateThread.id).map((entry) => entry.userId))
      const outsider = model.spaceMembersOf(privateThread.spaceId).find((id) => !inside.has(id))
      samples.privateThread = {
        chatId: privateThread.id.toString(),
        ...(outsider != null ? { outsiderUserId: outsider.toString() } : {}),
      }
    }
    const busy = inbox.filter((chat) => chat.count > 400).sort((left, right) => right.count - left.count)[0]
    const messages = busy ? model.lazy(busy.id) : undefined
    if (busy && messages) {
      for (const id of messages.idsBefore(BigInt(busy.count - 250), 200)) {
        const text = messages.peek(id)?.text ?? ""
        const word = text
          .split(/[\s.,!?;:()"]+/)
          .filter((candidate) => /^[a-z]{6,}$/i.test(candidate))
          .sort((left, right) => right.length - left.length)[0]
        if (word) {
          samples.search = { chatId: busy.id.toString(), query: word.toLowerCase(), messageId: id.toString() }
          break
        }
      }
    }
    this.sampled = samples
    return samples
  }

  // ---- Persistence ----------------------------------------------------------------

  private scheduleSave(urgent: boolean) {
    if (!this.options.store || this.persistence === "unavailable" || this.disposed || this.forgetful) return
    this.saveDirty = true
    if (urgent) {
      void this.flushSave()
    } else if (!this.saveTimer) {
      this.saveTimer = setTimeout(() => void this.flushSave(), SAVE_DELAY_MS)
    }
  }

  private flushSave(): Promise<void> {
    if (this.saveTimer) {
      clearTimeout(this.saveTimer)
      this.saveTimer = undefined
    }
    const store = this.options.store
    if (!this.saveDirty || !store || !this.model || this.forgetful) return this.saving
    this.saveDirty = false
    const state = this.model.persistedState()
    this.saving = this.saving.then(
      () =>
        store.save(state).catch((error: unknown) => {
          this.persistence = "unavailable"
          this.error = "The demo server could not save its state; it will not survive a reload"
          this.log.warn("persisted.save.failed", { error })
          this.scheduleStatus()
        }),
    )
    return this.saving
  }

  private async resetServer() {
    // Nothing more is saved by this world: the next load starts afresh.
    this.forgetful = true
    this.saveDirty = false
    if (this.saveTimer) clearTimeout(this.saveTimer)
    this.saveTimer = undefined
    await this.saving
    await this.options.store?.erase()
  }

  /** Bound what a long session keeps: frame logs, the RPC log, old journal records. */
  private tidy() {
    const transport = this.transport
    transport.sent.length = 0
    transport.delivered.length = 0
    transport.lost.length = 0
    if (this.endpoint) this.endpoint.dropped.length = 0
    const model = this.model
    if (!model) return
    model.rpcLog.length = 0
    model.readHistory.clear()
    model.sidecarsAheadOfPage.clear()
    model.staleReadsServed.clear()
    for (const bucketId of model.bucketIds()) {
      const seq = model.bucketSeq(bucketId)
      if (seq > JOURNAL_KEEP) model.pruneJournal(bucketId, seq - JOURNAL_KEEP)
    }
    this.scheduleStatus()
  }

  /** Stop timers and save what changed. The transport is closed for good. */
  async dispose() {
    if (this.disposed) return
    this.disposed = true
    this.stopStream()
    this.stopAgent()
    if (this.activityTimer) clearInterval(this.activityTimer)
    for (const entry of this.typing.values()) clearInterval(entry.timer)
    this.typing.clear()
    for (const timer of this.timers) clearTimeout(timer)
    this.timers.clear()
    if (this.housekeeping) clearInterval(this.housekeeping)
    if (this.statusTimer) clearTimeout(this.statusTimer)
    this.statusTimer = undefined
    await this.flushSave()
    this.endpoint?.dispose()
    this.transport.kill()
  }
}
