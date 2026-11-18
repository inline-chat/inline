import {
  DialogNotificationSettings_Mode,
  type ServerProtocolMessage,
} from "@inline-chat/protocol/core"
import { chatId as makeChatId, messageId as makeMessageId } from "@inline/ids"
import { DbObjectKind } from "../../database/models"
import { readMessages } from "../../realtime/transactions/read-messages"
import { sendMessage } from "../../realtime/transactions/send-message"
import type { SyncStorage } from "../../realtime/sync"
import { CoreHarness } from "../core-harness"
import { SeededRandom } from "../rng"
import { chatInputPeer, type FrameInterceptor } from "../server-model"
import { compareReplica, type Divergence } from "./compare"

/**
 * Seeded random schedules for the model-based sync test.
 *
 * One schedule is a list of steps drawn from a seeded generator: server-side
 * events (messages from other users, edits, deletes, reactions, reads on the
 * account's other device, space and no-op records), local intents (send,
 * mark read), and faults (duplicated frames, reordered frames, a connection
 * lost mid-stream, a lost RPC result, refused reconnects, time passing).
 * After the last step the harness heals and the replica is compared with
 * the model.
 *
 * Faults follow what a real connection can do. A single socket never drops
 * one frame and delivers the next, so a loss always takes the connection
 * with it; reordering happens only inside one instant of time.
 */

export type StepKind =
  | "post"
  | "edit"
  | "delete"
  | "react"
  | "unreact"
  | "otherDeviceRead"
  | "spaceMember"
  | "notificationMode"
  | "rawRecord"
  | "irrelevant"
  | "send"
  | "markRead"
  | "duplicate"
  | "reorder"
  | "connectionLoss"
  | "lostResult"
  | "refuse"
  | "advance"

export type PlantedBug =
  /** Sync storage advances a chat cursor every third page without applying it. */
  "cursor-ahead-of-projection"

export type ScheduleConfig = {
  steps: number
  chats: number
  otherUsers: number
  weights: Record<StepKind, number>
  plantBug?: PlantedBug
}

export const defaultWeights: Record<StepKind, number> = {
  post: 10,
  edit: 4,
  delete: 3,
  react: 3,
  unreact: 1,
  otherDeviceRead: 2,
  spaceMember: 1,
  notificationMode: 1,
  rawRecord: 1,
  irrelevant: 1,
  send: 6,
  markRead: 3,
  duplicate: 2,
  reorder: 2,
  connectionLoss: 2,
  lostResult: 1,
  refuse: 1,
  advance: 4,
}

export const defaultConfig: ScheduleConfig = {
  steps: 40,
  chats: 3,
  otherUsers: 3,
  weights: defaultWeights,
}

export type ScheduleResult = {
  seed: number
  config: ScheduleConfig
  trace: string[]
  divergences: Divergence[]
  /** Divergences not explained by a recorded bug. */
  unexpected: Divergence[]
  logs: string[]
  stats: { rpcs: number; framesDelivered: number; framesLost: number; reconnects: number }
}

const words = [
  "ship", "review", "deploy", "thread", "draft", "ok", "later", "تم", "مراجعة", "שלום",
  "בדיקה", "完成", "确认", "レビュー", "😀", "🚀", "naïve", "Straße", "резюме", "proof",
]

const textFor = (random: SeededRandom) => {
  const count = random.bool(0.15) ? random.int(30, 80) : random.int(1, 8)
  return Array.from({ length: count }, () => random.pick(words)).join(" ")
}

const emojis = ["👍", "❤️", "😂", "🎉", "👀"]

const plantedStorage = (bug: PlantedBug, inner: SyncStorage): SyncStorage => {
  let chatCommits = 0
  return {
    initialize: () => inner.initialize(),
    getState: () => inner.getState(),
    setState: (state) => inner.setState(state),
    getBucketState: (key) => inner.getBucketState(key),
    setBucketState: (key, state) => inner.setBucketState(key, state),
    removeBucketState: (key) => inner.removeBucketState(key),
    clear: () => inner.clear(),
    commitBucketState: async (key, state, apply) => {
      if (!inner.commitBucketState) throw new Error("planted bug needs commitBucketState")
      if (bug === "cursor-ahead-of-projection" && key.kind === "chat") {
        chatCommits += 1
        if (chatCommits % 3 === 0) {
          // The bug: the cursor commits, the page's projection does not.
          return await inner.commitBucketState(key, state, () => undefined)
        }
      }
      return await inner.commitBucketState(key, state, apply)
    },
  }
}

const updateKinds = (message: ServerProtocolMessage) =>
  message.body.oneofKind === "message" && message.body.message.payload.oneofKind === "update"
    ? message.body.message.payload.update.updates
    : []

/** `${chatId}:${messageId}` of reaction changes a frame carries. */
const reactionTargets = (message: ServerProtocolMessage) =>
  updateKinds(message).flatMap((update) => {
    if (update.update.oneofKind === "updateReaction") {
      const reaction = update.update.updateReaction.reaction
      return reaction ? [`${reaction.chatId}:${reaction.messageId}`] : []
    }
    if (update.update.oneofKind === "deleteReaction") {
      return [`${update.update.deleteReaction.chatId}:${update.update.deleteReaction.messageId}`]
    }
    return []
  })

export const runSchedule = async (
  seed: number,
  config: ScheduleConfig = defaultConfig,
): Promise<ScheduleResult> => {
  const random = new SeededRandom(seed)
  const trace: string[] = []
  const unverifiableReactions = new Set<string>()
  const plantBug = config.plantBug
  const harness = CoreHarness.create(
    plantBug
      ? { wrapSyncStorage: (storage: SyncStorage) => plantedStorage(plantBug, storage) }
      : {},
  )
  const { model } = harness
  const self = model.selfUserId
  const others = Array.from({ length: config.otherUsers }, (_, index) => BigInt(index + 2))
  const chatIds = Array.from({ length: config.chats }, (_, index) => BigInt(index + 10))
  const spaceId = 100n
  let reconnects = 0

  try {
    for (const id of others) model.addUser(id)
    model.addSpace(spaceId)
    for (const id of chatIds) {
      model.addChat({
        id,
        participants: others,
        ...(id % 2n === 0n ? { spaceId } : {}),
      })
      for (let index = 0; index < random.int(0, 3); index += 1) {
        model.postMessage({ chatId: id, fromId: random.pick(others), text: textFor(random) })
      }
    }

    await harness.boot()
    await harness.seedReplicaFromModel()
    await harness.runUntil(() => harness.connected(), { description: "first connection" })
    await harness.settle()

    const process = () => harness.process
    let interceptor: FrameInterceptor | undefined
    const setInterceptor = (next: FrameInterceptor | undefined) => {
      interceptor = next
      harness.intercept((frame) => {
        if (!interceptor) return "deliver"
        return interceptor(frame)
      })
    }
    setInterceptor(undefined)

    const liveMessages = (chatId?: bigint) =>
      Array.from(model.chats.values())
        .filter((chat) => chatId == null || chat.id === chatId)
        .flatMap((chat) => Array.from(chat.messages.values()))

    const markLostReactions = (frames: readonly ServerProtocolMessage[]) => {
      for (const frame of frames) for (const key of reactionTargets(frame)) unverifiableReactions.add(key)
    }

    const serverEvent = (kind: StepKind): string | undefined => {
      const chatId = random.pick(chatIds)
      switch (kind) {
        case "post": {
          const fromId = random.bool(0.1) ? self : random.pick(others)
          const message = model.postMessage({ chatId, fromId, text: textFor(random) })
          return `post chat=${chatId} id=${message.id} from=${fromId}`
        }
        case "edit": {
          const target = liveMessages(chatId)
          if (target.length === 0) return undefined
          const message = random.pick(target)
          model.editMessage(chatId, message.id, textFor(random))
          return `edit chat=${chatId} id=${message.id}`
        }
        case "delete": {
          const target = liveMessages(chatId)
          if (target.length === 0) return undefined
          const ids = random.shuffle(target.map((message) => message.id)).slice(0, random.int(1, 2))
          model.deleteMessages(chatId, ids)
          return `delete chat=${chatId} ids=${ids.join(",")}`
        }
        case "react":
        case "unreact": {
          const target = liveMessages(chatId)
          if (target.length === 0) return undefined
          const message = random.pick(target)
          // Reactions are realtime only: with no live session the change is
          // never pushed, and no replay will carry it until the message is
          // served again.
          if (process().endpoint.sessionId == null || process().transport.state !== "connected") {
            unverifiableReactions.add(`${chatId}:${message.id}`)
          }
          const userId = random.pick([self, ...others])
          if (kind === "react") {
            const emoji = random.pick(emojis)
            model.addReaction(chatId, message.id, userId, emoji)
            return `react chat=${chatId} id=${message.id} user=${userId} ${emoji}`
          }
          const existing = message.reactions[0]
          if (!existing) return undefined
          model.removeReaction(chatId, message.id, existing.userId, existing.emoji)
          return `unreact chat=${chatId} id=${message.id} user=${existing.userId}`
        }
        case "otherDeviceRead": {
          const target = liveMessages(chatId)
          const latest = target.reduce((max, message) => (message.id > max ? message.id : max), 0n)
          if (latest === 0n) return undefined
          const maxId = BigInt(random.int(1, Number(latest)))
          model.readOnOtherDevice(chatId, maxId)
          return `otherDeviceRead chat=${chatId} max=${maxId}`
        }
        case "spaceMember": {
          const members = model.spaceMemberUserIds(spaceId)
          if (members.length > 0 && random.bool(0.35)) {
            const userId = random.pick(members)
            model.removeSpaceMember(spaceId, userId)
            return `spaceMemberRemove space=${spaceId} user=${userId}`
          }
          const userId = BigInt(random.int(50, 60))
          model.addSpaceMember(spaceId, userId)
          return `spaceMember space=${spaceId} user=${userId}`
        }
        case "notificationMode": {
          const mode = random.pick([
            undefined,
            DialogNotificationSettings_Mode.ALL,
            DialogNotificationSettings_Mode.MENTIONS,
            DialogNotificationSettings_Mode.NONE,
          ])
          model.setNotificationMode(chatId, mode)
          return `notificationMode chat=${chatId} mode=${mode ?? "global"}`
        }
        case "rawRecord":
          model.addRawRecord()
          return "rawRecord user"
        case "irrelevant": {
          const bucket = random.bool() ? "user" : (`space:${spaceId}` as const)
          model.addIrrelevantRecord(bucket)
          return `irrelevant ${bucket}`
        }
        default:
          return undefined
      }
    }

    const localIntent = (kind: "send" | "markRead"): string | undefined => {
      const chatId = random.pick(chatIds)
      const { client, db } = process()
      if (kind === "send") {
        const text = textFor(random)
        void client
          .execute(
            sendMessage({ chatId: makeChatId(chatId), peerId: chatInputPeer(chatId), text }),
          )
          .catch(() => undefined)
        return `send chat=${chatId} ${JSON.stringify(text.slice(0, 24))}`
      }
      const chat = db.get(db.ref(DbObjectKind.Chat, makeChatId(chatId)))
      const lastMsgId = chat?.lastMsgId
      if (lastMsgId == null || BigInt(lastMsgId) <= 0n) return undefined
      void client
        .execute(
          readMessages({ peerId: chatInputPeer(chatId), maxId: makeMessageId(lastMsgId) }),
        )
        .catch(() => undefined)
      return `markRead chat=${chatId} max=${lastMsgId}`
    }

    const serverKinds: StepKind[] = [
      "post", "edit", "delete", "react", "unreact", "otherDeviceRead", "spaceMember",
      "notificationMode", "rawRecord", "irrelevant",
    ]

    for (let step = 0; step < config.steps; step += 1) {
      const kind = random.weighted(config.weights)
      let line: string | undefined
      if (serverKinds.includes(kind)) {
        line = serverEvent(kind)
      } else if (kind === "send" || kind === "markRead") {
        line = localIntent(kind)
      } else if (kind === "duplicate") {
        let remaining = random.int(1, 3)
        setInterceptor((frame) => {
          if (frame.kind !== "push" && frame.kind !== "result") return "deliver"
          remaining -= 1
          if (remaining <= 0) setInterceptor(undefined)
          return "duplicate"
        })
        line = serverEvent(random.pick(["post", "edit", "delete"] as const))
        line = `duplicate next frames; ${line ?? "nothing"}`
      } else if (kind === "reorder") {
        const { transport } = process()
        transport.hold()
        const events = Array.from({ length: random.int(2, 4) }, () =>
          serverEvent(random.pick(["post", "edit", "delete", "react"] as const)),
        )
        const held = transport.held()
        const order = random.shuffle(held.map((_, index) => index))
        const permuted = order.some((value, index) => value !== index)
        if (permuted) markLostReactions(held)
        await transport.release(order)
        line = `reorder [${order.join(",")}] ${events.filter(Boolean).join("; ")}`
      } else if (kind === "connectionLoss") {
        if (random.bool()) {
          await process().transport.disconnect("schedule")
          line = "connectionLoss now"
        } else {
          setInterceptor((frame) => {
            if (frame.kind !== "push") return "deliver"
            setInterceptor(undefined)
            return "drop-and-disconnect"
          })
          const event = serverEvent(random.pick(["post", "edit", "delete"] as const))
          line = `connectionLoss losing next push; ${event ?? "nothing"}`
        }
        reconnects += 1
      } else if (kind === "lostResult") {
        setInterceptor((frame) => {
          if (frame.kind !== "result") return "deliver"
          setInterceptor(undefined)
          return "drop-and-disconnect"
        })
        line = `lostResult; ${localIntent(random.pick(["send", "markRead"] as const)) ?? "nothing"}`
        reconnects += 1
      } else if (kind === "refuse") {
        const { transport } = process()
        transport.connectPolicy = "refuse"
        await transport.disconnect("schedule")
        await harness.clock.advance(2_500)
        transport.connectPolicy = "accept"
        line = "refuse two reconnects"
        reconnects += 1
      } else if (kind === "advance") {
        const ms = random.int(100, 20_000)
        await harness.clock.advance(ms)
        line = `advance ${ms}ms`
      }
      if (line) trace.push(`${step}: ${line}`)
      await harness.settle()
      if (!interceptor && process().transport.state === "idle" && random.bool(0.5)) {
        await harness.clock.advance(1_000)
      }
    }

    setInterceptor(undefined)
    await harness.heal()
    const { transport, endpoint } = process()
    markLostReactions(transport.lost.map((frame) => frame.message))
    markLostReactions(endpoint.dropped.map((frame) => frame.message))

    const replica = await harness.snapshot()
    const divergences = compareReplica(model, replica, { unverifiableReactions })
    return {
      seed,
      config,
      trace,
      divergences,
      unexpected: divergences.filter((divergence) => !divergence.knownBug),
      logs: harness.recentLogs(),
      stats: {
        rpcs: model.rpcLog.length,
        framesDelivered: transport.delivered.length,
        framesLost: transport.lost.length,
        reconnects,
      },
    }
  } finally {
    await harness.dispose()
  }
}

/** A failure report with the seed and a one-line replay recipe. */
export const formatReport = (result: ScheduleResult, testFile = "src/testing/model-sync.test.ts") =>
  [
    `Model-based sync diverged for seed ${result.seed}.`,
    `Replay: MODEL_SYNC_SEED=${result.seed} MODEL_SYNC_STEPS=${result.config.steps} bunx vitest run ${testFile}`,
    "",
    "Divergences:",
    ...result.divergences.map(
      (divergence) =>
        `  - ${divergence.property}${divergence.chatId ? ` chat=${divergence.chatId}` : ""}: ${divergence.detail}` +
        (divergence.knownBug ? ` [${divergence.knownBug}]` : ""),
    ),
    "",
    "Schedule:",
    ...result.trace.map((line) => `  ${line}`),
    "",
    `Stats: ${JSON.stringify(result.stats)}`,
    "",
    "Last core log events:",
    ...result.logs.slice(-25).map((line) => `  ${line}`),
  ].join("\n")
