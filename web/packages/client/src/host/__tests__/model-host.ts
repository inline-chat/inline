/**
 * The real `CoreHost` (Db on in-memory SQLite, realtime client, sync engine,
 * outbox, queries) against the test server model, under fake time. The only
 * fake is the wire: `ScriptedTransport` + `ModelServerEndpoint`.
 *
 * The model answers the RPCs the host features need that it does not answer
 * itself (edit, delete, reactions, logout) by applying its own events and
 * returning the updates they produce, as the server does.
 */
import { Method, RpcError_Code, type RpcCall, type Update } from "@inline-chat/protocol/core"
import type { Intent, IntentResult, TxId } from "@inline/core-protocol"
import { userId as makeUserId, type UserID } from "@inline/ids"
import { Log } from "@inline/log"
import { Db } from "../../database"
import { DbObjectKind, type DbModel } from "../../database/models"
import { syncBucketId } from "../../realtime/sync/sync-types"
import { bucketKeyFor } from "../../testing/core-harness"
import { ScriptedTransport, serverMessage } from "../../testing/scripted-transport"
import {
  ModelServerEndpoint,
  ServerModel,
  encodeChat,
  encodeDialog,
  encodeMessage,
  encodeUser,
  type RpcOutcome,
} from "../../testing/server-model"
import { inputPeerChatId } from "../../testing/server-model/protocol"
import { useFakeTime, type FakeTime } from "../../testing/virtual-clock"
import type { HostStorage } from "../account-core"
import { CoreHost, type CoreHostOptions } from "../core-host"
import { FakeDisk, TestContext } from "./fixtures"
import {
  upsertChat,
  upsertDialog,
  upsertMessage,
  upsertUser,
} from "../../realtime/transactions/mappers"

const quiet = () => new Log("ModelHost", { sink: false })

export const SELF = 1n
export const self: UserID = makeUserId(SELF)

export type ModelHostOptions = {
  startMs?: number
  /** Extra host options (timeouts). */
  host?: Partial<CoreHostOptions>
}

/** RPCs the model answers here, logged for assertions. */
export type ExtraRpc = { method: Method; input: RpcCall["input"] }

export class ModelHost {
  readonly time: FakeTime
  readonly model: ServerModel
  readonly disk = new FakeDisk()
  readonly extraRpcs: ExtraRpc[] = []
  /** Answer an RPC with this error code instead of applying it. */
  fail: ((input: RpcCall["input"]) => RpcError_Code | undefined) | undefined
  transport!: ScriptedTransport
  endpoint!: ModelServerEndpoint
  host!: CoreHost
  ui!: TestContext
  private captured: Update[] | undefined
  private nextInteractionId = 77n
  /** Answer RPCs the model does not know (logged in `extraRpcs`); undefined passes on. */
  respond: ((method: Method, input: RpcCall["input"]) => RpcOutcome | undefined) | undefined
  /** Wrap the storage each start opens (faults in erasing, for example). */
  storageWrap: ((storage: HostStorage) => HostStorage) | undefined
  /** Called when a message action reaches the server, with its interaction ID. */
  onAction: ((interactionId: bigint) => void) | undefined

  constructor(options: ModelHostOptions = {}) {
    this.time = useFakeTime({ startMs: options.startMs ?? Date.UTC(2026, 10, 17, 9) })
    this.model = new ServerModel({ selfUserId: SELF, now: () => this.time.nowSeconds() })
    this.model.addUser(SELF, "Me")
    // A session that only listens, so an event's updates can be returned as
    // an RPC's result as well as pushed.
    this.model.connect((push) => {
      if (this.captured) this.captured.push(...push.updates)
    })
    const handle = this.model.handleRpc.bind(this.model)
    this.model.handleRpc = (session, method, input) => {
      const failure = this.fail?.(input)
      if (failure != null) {
        this.model.rpcLog.push({ session, method, ok: false })
        return { error: { code: failure, message: "scripted failure" } }
      }
      const answered = this.respond?.(method, input)
      if (answered) {
        this.extraRpcs.push({ method, input })
        this.model.rpcLog.push({ session, method, ok: !("error" in answered) })
        return answered
      }
      return this.extra(method, input) ?? handle(session, method, input)
    }
    this.hostOptions = options.host ?? {}
  }

  private readonly hostOptions: Partial<CoreHostOptions>

  /** Write the model's state into the replica, as a device that synced earlier would hold it. */
  async seedDisk(extra: DbModel[] = [], edit?: (db: Db) => void) {
    const db = new Db({ persistenceStore: this.disk.store(), autoHydrate: false, logger: quiet() })
    await this.settleUntil(db.openPersistence())
    const model = this.model
    await this.settleUntil(
      db.commit(() => {
        for (const user of model.users.values()) upsertUser(db, encodeUser(user))
        for (const chat of model.chats.values()) {
          upsertChat(db, encodeChat(chat))
          const dialog = model.dialogs.get(chat.id)
          if (dialog) upsertDialog(db, encodeDialog(chat, dialog, model.unreadCount(chat.id)))
          for (const message of chat.messages.values()) {
            upsertMessage(db, encodeMessage(message, model.selfUserId))
          }
        }
        for (const bucketId of model.bucketIds()) {
          db.replace({
            kind: DbObjectKind.SyncBucketState,
            id: syncBucketId(bucketKeyFor(bucketId)),
            seq: model.bucketSeq(bucketId),
            date: this.time.nowSeconds(),
          })
        }
        db.replace({ kind: DbObjectKind.SyncGlobalState, id: 0, lastSyncDate: this.time.nowSeconds() })
        for (const object of extra) db.replace(object)
        edit?.(db)
      }),
    )
    await this.settleUntil(db.closePersistence())
  }

  /** Start a host on the disk, signed in, with a UI context (offline: without a network). */
  async start(options: { online?: boolean } = {}) {
    const online = options.online ?? true
    // Pongs are answered a tick after the ping, not inside its `send`: the
    // ping-pong service registers a ping only after `send` resolves, so an
    // instant pong would go unmatched and drop the connection 30 s later.
    const transport = new ScriptedTransport({ connectPolicy: "accept", autoPong: false })
    transport.onClientMessage((message) => {
      if (message.body.oneofKind !== "ping") return
      const nonce = message.body.ping.nonce
      setTimeout(() => {
        void transport.deliver(serverMessage({ oneofKind: "pong", pong: { nonce } }))
      }, 1)
    })
    this.transport = transport
    this.endpoint = new ModelServerEndpoint(this.model, this.transport)
    this.host = new CoreHost({
      buildId: "2026-11-17T00:00:00Z-model",
      openStorage: () => (this.storageWrap ? this.storageWrap(this.disk.storage()) : this.disk.storage()),
      createTransport: () => this.transport,
      realtime: { connection: { backoffDelayMs: () => 500 } },
      logger: quiet(),
      now: () => this.time.now(),
      ...this.hostOptions,
    })
    this.ui = new TestContext(this.host)
    if (!online) this.ui.post({ kind: "signal", signal: { kind: "online", online: false } })
    this.ui.post({ kind: "session", action: "start", session: { userId: self, token: "model" } })
    this.ui.subscribeTo(1, { kind: "core" })
    await this.until(() => this.ui.core(1)?.phase === "ready", "ready")
    if (!online) return this
    await this.until(() => this.ui.core(1)?.connection === "connected", "connected")
    await this.synced()
    return this
  }

  /** Stop the host without erasing (a restart keeps the disk). */
  async stop() {
    await this.settleUntil(this.host.shutdown())
    this.transport.kill()
    this.endpoint.dispose()
  }

  async dispose() {
    try {
      if (this.host) await this.settleUntil(this.host.shutdown()).catch(() => undefined)
      this.transport?.kill()
      this.endpoint?.dispose()
    } finally {
      this.time.dispose()
    }
  }

  until(predicate: () => boolean, description: string, maxMs = 60_000) {
    return this.time.runUntil(predicate, { stepMs: 50, maxMs, description })
  }

  async settleUntil<T>(promise: Promise<T>, maxMs = 120_000): Promise<T> {
    let outcome: { value: T } | { error: unknown } | undefined
    promise.then(
      (value) => {
        outcome = { value }
      },
      (error: unknown) => {
        outcome = { error }
      },
    )
    await this.time.runUntil(() => outcome != null, { stepMs: 50, maxMs, description: "awaited promise" })
    if ("error" in outcome!) throw outcome.error
    return outcome!.value
  }

  /** Wait until the host has applied everything it was sent. */
  async synced() {
    await this.settleUntil(this.endpoint.idle())
    await this.settleUntil(this.host.idle())
    await this.time.settle()
  }

  intent(tx: TxId, intent: Intent) {
    this.ui.post({ kind: "intent", tx, intent })
  }

  /** Every result reported for `tx`, in order. */
  results(tx: TxId): IntentResult["status"][] {
    return this.ui.settled.filter((result) => result.tx === tx).map((result) => result.status)
  }

  async final(tx: TxId, description = `final result of ${tx}`): Promise<IntentResult> {
    await this.until(() => {
      const last = this.ui.result(tx)
      return last != null && last.status !== "accepted"
    }, description)
    return this.ui.result(tx)!
  }

  // ---- RPCs the model does not answer itself ---------------------------

  /** The updates a model event produces, as an RPC returns them. */
  captureUpdates(run: () => void): Update[] {
    return this.capture(run)
  }

  private capture(run: () => void): Update[] {
    this.captured = []
    try {
      run()
      return this.captured
    } finally {
      this.captured = undefined
    }
  }

  private extra(method: Method, input: RpcCall["input"]): RpcOutcome | undefined {
    const kind = input.oneofKind
    if (
      kind !== "editMessage" &&
      kind !== "deleteMessages" &&
      kind !== "addReaction" &&
      kind !== "deleteReaction" &&
      kind !== "invokeMessageAction" &&
      kind !== "logOut"
    ) {
      return undefined
    }
    this.extraRpcs.push({ method, input })
    this.model.rpcLog.push({ session: -1, method, ok: true })
    switch (input.oneofKind) {
      case "invokeMessageAction": {
        const interactionId = this.nextInteractionId++
        this.onAction?.(interactionId)
        return {
          result: { oneofKind: "invokeMessageAction", invokeMessageAction: { interactionId } },
        }
      }
      case "logOut":
        return { result: { oneofKind: "logOut", logOut: { loggedOut: true } } }
      case "editMessage": {
        const chatId = inputPeerChatId(input.editMessage.peerId)
        if (chatId == null) return undefined
        const updates = this.capture(() =>
          this.model.editMessage(chatId, input.editMessage.messageId, input.editMessage.text),
        )
        return { result: { oneofKind: "editMessage", editMessage: { updates } } }
      }
      case "deleteMessages": {
        const chatId = inputPeerChatId(input.deleteMessages.peerId)
        if (chatId == null) return undefined
        const updates = this.capture(() =>
          this.model.deleteMessages(chatId, input.deleteMessages.messageIds),
        )
        return { result: { oneofKind: "deleteMessages", deleteMessages: { updates } } }
      }
      case "addReaction": {
        const chatId = inputPeerChatId(input.addReaction.peerId)
        if (chatId == null) return undefined
        const updates = this.capture(() =>
          this.model.addReaction(chatId, input.addReaction.messageId, SELF, input.addReaction.emoji),
        )
        return { result: { oneofKind: "addReaction", addReaction: { updates } } }
      }
      case "deleteReaction": {
        const chatId = inputPeerChatId(input.deleteReaction.peerId)
        if (chatId == null) return undefined
        const updates = this.capture(() =>
          this.model.removeReaction(chatId, input.deleteReaction.messageId, SELF, input.deleteReaction.emoji),
        )
        return { result: { oneofKind: "deleteReaction", deleteReaction: { updates } } }
      }
    }
    return undefined
  }
}
