import {
  ClientMessage,
  ConnectionError_Reason,
  GetUpdatesResult_ResultType,
  Method,
  RpcError_Code,
  ServerProtocolMessage,
  Update,
  type GetUpdatesResult,
  type GetUpdatesStateResult,
  type RpcCall,
  type RpcResult,
} from "@inline-chat/protocol/core"
import { AsyncChannel } from "../utils/async-channel"
import type { TransportEvent } from "../realtime/types"
import { TransportError, type Transport } from "../realtime/transport/transport"
import { realTurn } from "./event-loop"

/**
 * The server end of the client's `Transport`, driven step by step by a test.
 *
 * Every frame crosses a real protobuf encode and decode in both directions,
 * so what the test inspects is what would be on the wire. Server-to-client
 * frames pass through an outbound queue where they can be held, dropped,
 * duplicated, reordered or delayed before the client sees them.
 *
 * Connection attempts follow `connectPolicy`: `"manual"` waits for the test
 * to call `accept()` or `refuse()`; `"accept"` and `"refuse"` answer at once.
 */

export type ScriptedTransportState = "idle" | "connecting" | "connected" | "dead"

export type ConnectPolicy = "manual" | "accept" | "refuse"

export type RpcCallFrame = {
  /** The client message ID, which the result must name as `reqMsgId`. */
  id: bigint
  method: Method
  input: RpcCall["input"]
  message: ClientMessage
  connection: number
}

export type OutboundFrame = {
  message: ServerProtocolMessage
  /** The connection the frame was sent on; a frame never crosses to a new one. */
  connection: number
}

export type ClientMessageListener = (
  message: ClientMessage,
  transport: ScriptedTransport,
) => void

let nextServerMessageId = 1n

const serverMessage = (
  body: ServerProtocolMessage["body"],
): ServerProtocolMessage =>
  ServerProtocolMessage.create({ id: nextServerMessageId++, body })

const roundTripServer = (message: ServerProtocolMessage) =>
  ServerProtocolMessage.fromBinary(ServerProtocolMessage.toBinary(message))

const roundTripClient = (message: ClientMessage) =>
  ClientMessage.fromBinary(ClientMessage.toBinary(message))

export const methodName = (method: Method) => Method[method] ?? String(method)

/** A short label for logs and failure reports. */
export const describeServerFrame = (message: ServerProtocolMessage): string => {
  const body = message.body
  switch (body.oneofKind) {
    case "rpcResult":
      return `rpcResult(${body.rpcResult.result.oneofKind ?? "?"}#${body.rpcResult.reqMsgId})`
    case "rpcError":
      return `rpcError(${RpcError_Code[body.rpcError.errorCode]}#${body.rpcError.reqMsgId})`
    case "message": {
      const payload = body.message.payload
      if (payload.oneofKind !== "update") return `message(${payload.oneofKind ?? "?"})`
      return `updates[${payload.update.updates
        .map((update) =>
          `${update.update.oneofKind ?? "?"}${update.seq ? `@${update.seq}` : ""}`,
        )
        .join(",")}]`
    }
    default:
      return body.oneofKind ?? "empty"
  }
}

export class ScriptedTransport implements Transport {
  readonly events = new AsyncChannel<TransportEvent>()
  /** Every client frame, decoded from its wire bytes, in send order. */
  readonly sent: ClientMessage[] = []
  /** Server frames lost because their connection ended before delivery. */
  readonly lost: OutboundFrame[] = []
  /** Server frames the client received, in order. */
  readonly delivered: ServerProtocolMessage[] = []

  state: ScriptedTransportState = "idle"
  connectPolicy: ConnectPolicy
  /** Answer pings immediately, outside the outbound queue. Default on. */
  autoPong: boolean
  connectionAttempts = 0
  /** Increments on every accepted connection. */
  connection = 0

  private holding = false
  private readonly outbound: OutboundFrame[] = []
  private readonly answered = new Set<bigint>()
  private readonly listeners = new Set<ClientMessageListener>()
  private dropClientFrames: Array<(message: ClientMessage) => boolean> = []
  private frameCounter = 0

  constructor(
    options: { connectPolicy?: ConnectPolicy; autoPong?: boolean } = {},
  ) {
    this.connectPolicy = options.connectPolicy ?? "manual"
    this.autoPong = options.autoPong ?? true
  }

  /** Monotonic count of frames in either direction; a settle progress signal. */
  get activity() {
    return this.frameCounter
  }

  // ---- Transport ------------------------------------------------------

  async start() {
    if (this.state === "dead") return
    if (this.state !== "idle") return
    this.state = "connecting"
    this.connectionAttempts += 1
    this.frameCounter += 1
    await this.events.send({ type: "connecting" })
    if (this.connectPolicy === "accept") await this.accept()
    else if (this.connectPolicy === "refuse") await this.refuse()
  }

  async stop() {
    if (this.state === "idle" || this.state === "dead") return
    this.endConnection()
    this.state = "idle"
    await this.events.send({ type: "stopping" })
  }

  async send(message: ClientMessage) {
    if (this.state !== "connected") throw TransportError.notConnected()
    const decoded = roundTripClient(message)
    const dropIndex = this.dropClientFrames.findIndex((matches) => matches(decoded))
    this.frameCounter += 1
    this.sent.push(decoded)
    if (dropIndex >= 0) {
      // Lost before reaching the server: recorded as sent, never seen.
      this.dropClientFrames.splice(dropIndex, 1)
      return
    }
    if (decoded.body.oneofKind === "ping" && this.autoPong) {
      await this.emit(
        serverMessage({
          oneofKind: "pong",
          pong: { nonce: decoded.body.ping.nonce },
        }),
      )
    }
    for (const listener of this.listeners) listener(decoded, this)
  }

  // ---- Connection control ---------------------------------------------

  /** Complete the pending connection attempt. */
  async accept() {
    if (this.state !== "connecting") {
      throw new Error(`Cannot accept a connection in state ${this.state}`)
    }
    this.state = "connected"
    this.connection += 1
    this.frameCounter += 1
    await this.events.send({ type: "connected" })
  }

  /** Fail the pending connection attempt, as a socket error would. */
  async refuse(reason = "scripted-refusal") {
    if (this.state !== "connecting") {
      throw new Error(`Cannot refuse a connection in state ${this.state}`)
    }
    this.state = "idle"
    this.frameCounter += 1
    await this.events.send({ type: "disconnected", reason })
  }

  /**
   * Drop the live connection. Held and delayed frames on it are lost, as
   * they would be on a real socket.
   */
  async disconnect(reason = "scripted-disconnect") {
    if (this.state !== "connected" && this.state !== "connecting") return
    this.endConnection()
    this.state = "idle"
    this.frameCounter += 1
    await this.events.send({ type: "disconnected", reason })
  }

  /** The process is gone: nothing is sent or received again. */
  kill() {
    this.endConnection()
    this.state = "dead"
    this.listeners.clear()
  }

  /** Accept, wait for `connectionInit`, then send `connectionOpen`. */
  async open() {
    if (this.state === "connecting") await this.accept()
    const connection = this.connection
    const hasInit = () =>
      this.rpcsConnectionCount() >= connection
    for (let turn = 0; turn < 100 && !hasInit(); turn += 1) await realTurn()
    if (!hasInit()) throw new Error("The client did not send connectionInit")
    await this.deliver(
      serverMessage({ oneofKind: "connectionOpen", connectionOpen: {} }),
    )
  }

  /** Reject the handshake, as the server does for a bad or revoked token. */
  async rejectConnection(reason: ConnectionError_Reason) {
    await this.deliver(
      serverMessage({ oneofKind: "connectionError", connectionError: { reason } }),
    )
  }

  // ---- Server end -----------------------------------------------------

  /** Observe client frames as they arrive (the server model attaches here). */
  onClientMessage(listener: ClientMessageListener) {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  /** Lose the next client frame that matches, before the server sees it. */
  dropNextClientFrame(matches: (message: ClientMessage) => boolean) {
    this.dropClientFrames.push(matches)
  }

  /**
   * Send a frame to the client. While holding, it waits in the outbound
   * queue. A frame for a connection that has ended is lost.
   */
  async deliver(message: ServerProtocolMessage) {
    if (this.state !== "connected") {
      this.lost.push({ message, connection: this.connection })
      return
    }
    const frame = { message, connection: this.connection }
    if (this.holding) {
      this.outbound.push(frame)
      return
    }
    await this.emit(message)
  }

  async pushUpdates(updates: Update[]) {
    await this.deliver(
      serverMessage({
        oneofKind: "message",
        message: {
          payload: { oneofKind: "update", update: { updates } },
        },
      }),
    )
  }

  /** Deliver `message` after `delayMs` of (virtual) time. */
  deliverAfter(delayMs: number, message: ServerProtocolMessage) {
    const connection = this.connection
    setTimeout(() => {
      if (this.connection !== connection || this.state !== "connected") {
        this.lost.push({ message, connection })
        return
      }
      void this.deliver(message)
    }, delayMs)
  }

  // ---- Outbound queue faults -------------------------------------------

  /** Queue server frames instead of delivering them. */
  hold() {
    this.holding = true
  }

  get isHolding() {
    return this.holding
  }

  /** Frames waiting in the outbound queue. */
  held(): readonly ServerProtocolMessage[] {
    return this.outbound.map((frame) => frame.message)
  }

  /**
   * Stop holding and deliver the queue. `order` lists queue indexes to
   * deliver; indexes left out are dropped, repeated ones are duplicated.
   */
  async release(order?: readonly number[]) {
    this.holding = false
    const frames = this.outbound.splice(0)
    const indexes = order ?? frames.map((_, index) => index)
    for (const index of indexes) {
      const frame = frames[index]
      if (!frame) throw new RangeError(`No held frame at index ${index}`)
      if (frame.connection !== this.connection || this.state !== "connected") {
        this.lost.push(frame)
        continue
      }
      await this.emit(frame.message)
    }
  }

  /** Remove held frames that match. Returns how many were dropped. */
  dropHeld(matches: (message: ServerProtocolMessage) => boolean) {
    let dropped = 0
    for (let index = this.outbound.length - 1; index >= 0; index -= 1) {
      const frame = this.outbound[index]
      if (frame && matches(frame.message)) {
        this.outbound.splice(index, 1)
        this.lost.push(frame)
        dropped += 1
      }
    }
    return dropped
  }

  // ---- RPC inspection and answers --------------------------------------

  /** Every RPC the client sent, optionally of one method. */
  rpcs(method?: Method): RpcCallFrame[] {
    const calls: RpcCallFrame[] = []
    let connection = 0
    for (const message of this.sent) {
      if (message.body.oneofKind === "connectionInit") connection += 1
      if (message.body.oneofKind !== "rpcCall") continue
      const call = message.body.rpcCall
      if (method != null && call.method !== method) continue
      calls.push({
        id: message.id,
        method: call.method,
        input: call.input,
        message,
        connection,
      })
    }
    return calls
  }

  /** RPCs not yet answered through this transport's helpers. */
  pendingRpcs(method?: Method) {
    return this.rpcs(method).filter((call) => !this.answered.has(call.id))
  }

  /** The oldest unanswered RPC, optionally of one method. */
  nextRpc(method?: Method): RpcCallFrame | undefined {
    return this.pendingRpcs(method)[0]
  }

  requireRpc(method?: Method): RpcCallFrame {
    const call = this.nextRpc(method)
    if (!call) {
      throw new Error(
        `Expected a pending ${method == null ? "RPC" : methodName(method)}; sent: ` +
          this.sent.map((message) => message.body.oneofKind).join(", "),
      )
    }
    return call
  }

  async ack(call: RpcCallFrame | bigint) {
    const msgId = typeof call === "bigint" ? call : call.id
    await this.deliver(serverMessage({ oneofKind: "ack", ack: { msgId } }))
  }

  async answer(call: RpcCallFrame | bigint, result: RpcResult["result"]) {
    const reqMsgId = typeof call === "bigint" ? call : call.id
    this.answered.add(reqMsgId)
    await this.deliver(
      serverMessage({ oneofKind: "rpcResult", rpcResult: { reqMsgId, result } }),
    )
  }

  async fail(
    call: RpcCallFrame | bigint,
    errorCode: RpcError_Code,
    message = RpcError_Code[errorCode] ?? "error",
    code = 400,
  ) {
    const reqMsgId = typeof call === "bigint" ? call : call.id
    this.answered.add(reqMsgId)
    await this.deliver(
      serverMessage({
        oneofKind: "rpcError",
        rpcError: { reqMsgId, errorCode, message, code, retryAfterSeconds: 0 },
      }),
    )
  }

  /** Mark an RPC as handled without answering it (its result is lost). */
  forget(call: RpcCallFrame | bigint) {
    this.answered.add(typeof call === "bigint" ? call : call.id)
  }

  // ---- Common exchanges --------------------------------------------------

  async answerGetUpdatesState(
    call: RpcCallFrame,
    result: Partial<GetUpdatesStateResult> & { date: bigint },
  ) {
    await this.answer(call, {
      oneofKind: "getUpdatesState",
      getUpdatesState: { updatesFound: false, ...result },
    })
  }

  async answerGetUpdates(call: RpcCallFrame, page: Partial<GetUpdatesResult>) {
    const updates = page.updates ?? []
    await this.answer(call, {
      oneofKind: "getUpdates",
      getUpdates: {
        updates,
        seq: page.seq ?? 0n,
        date: page.date ?? 0n,
        final: page.final ?? true,
        resultType:
          page.resultType ??
          (updates.length === 0
            ? GetUpdatesResult_ResultType.EMPTY
            : GetUpdatesResult_ResultType.SLICE),
        skippedSequences: page.skippedSequences ?? [],
        ...(page.sidecars ? { sidecars: page.sidecars } : {}),
      },
    })
  }

  /** Acknowledge a send the way the server does: message ID, then the message. */
  async answerSendMessage(
    call: RpcCallFrame,
    receipt: { messageId: bigint; seq?: number; date?: bigint; fromId: bigint },
  ) {
    if (call.input.oneofKind !== "sendMessage") {
      throw new Error(`Expected sendMessage, got ${call.input.oneofKind}`)
    }
    const input = call.input.sendMessage
    const peer = input.peerId?.type
    const chatId = peer?.oneofKind === "chat" ? peer.chat.chatId : 0n
    const date = receipt.date ?? input.temporarySendDate ?? 0n
    const updates: Update[] = [
      Update.create({
        update: {
          oneofKind: "updateMessageId",
          updateMessageId: { messageId: receipt.messageId, randomId: input.randomId ?? 0n },
        },
      }),
      Update.create({
        seq: receipt.seq,
        date,
        update: {
          oneofKind: "newMessage",
          newMessage: {
            message: {
              id: receipt.messageId,
              fromId: receipt.fromId,
              chatId,
              peerId: { type: { oneofKind: "chat", chat: { chatId } } },
              message: input.message,
              out: true,
              date,
            },
          },
        },
      }),
    ]
    await this.answer(call, {
      oneofKind: "sendMessage",
      sendMessage: { updates, addedUserIds: [], unaddedUserIds: [] },
    })
  }

  // ---- Internals --------------------------------------------------------

  private rpcsConnectionCount() {
    return this.sent.filter((message) => message.body.oneofKind === "connectionInit").length
  }

  private async emit(message: ServerProtocolMessage) {
    const decoded = roundTripServer(message)
    this.frameCounter += 1
    this.delivered.push(decoded)
    await this.events.send({ type: "message", message: decoded })
  }

  private endConnection() {
    for (const frame of this.outbound.splice(0)) this.lost.push(frame)
    this.holding = false
  }
}

export { serverMessage }
