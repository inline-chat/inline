import {
  ConnectionError_Reason,
  type ClientMessage,
  type Method,
  type RpcCall,
  type ServerProtocolMessage,
} from "@inline-chat/protocol/core"
import {
  serverMessage,
  type ScriptedTransport,
} from "../scripted-transport"
import type { ModelPush, ModelSession, RpcOutcome, ServerModel } from "./model"

/**
 * Connects a `ServerModel` to a `ScriptedTransport`, so a real
 * `RealtimeClient` talks to the model as it would to the server:
 * `connectionInit` opens a session, RPCs are acknowledged and answered,
 * and the model's live pushes reach the session.
 *
 * Every server frame goes through `interceptor` first. It decides what
 * happens to that frame (deliver, drop, duplicate, hold for reordering), so
 * a test can inject faults frame by frame without touching the model.
 */

export type FrameKind = "open" | "ack" | "result" | "push" | "hint"

export type OutgoingFrame = {
  kind: FrameKind
  message: ServerProtocolMessage
  push?: ModelPush
}

export type FrameDecision =
  | "deliver"
  | "drop"
  | "duplicate"
  /** Deliver, then drop the connection before anything else goes out. */
  | "deliver-then-disconnect"
  /** Drop this frame and the connection with it (a socket dying mid-write). */
  | "drop-and-disconnect"

export type FrameInterceptor = (frame: OutgoingFrame) => FrameDecision

export type ModelServerEndpointOptions = {
  /** Answer `connectionInit` with `connectionOpen` automatically. Default on. */
  autoOpen?: boolean
  /** Send an `ack` before each RPC result. Default on. */
  ackRpcs?: boolean
  /** Reject handshakes with this reason instead of opening. */
  rejectWith?: ConnectionError_Reason
  interceptor?: FrameInterceptor
  /**
   * Called when an RPC reaches the server, before the model answers it. A
   * test uses it to make something happen "while the server is working",
   * for instance a message arriving between a request and its page.
   */
  beforeRpc?: (call: { method: Method; input: RpcCall["input"] }) => void
}

export class ModelServerEndpoint {
  interceptor: FrameInterceptor
  beforeRpc: ((call: { method: Method; input: RpcCall["input"] }) => void) | undefined
  autoOpen: boolean
  ackRpcs: boolean
  rejectWith: ConnectionError_Reason | undefined
  /** Frames the interceptor dropped, for reports. */
  readonly dropped: OutgoingFrame[] = []

  private session: ModelSession | undefined
  private sessionConnection = -1
  private readonly detach: () => void
  private queue: Promise<void> = Promise.resolve()

  constructor(
    readonly model: ServerModel,
    readonly transport: ScriptedTransport,
    options: ModelServerEndpointOptions = {},
  ) {
    this.autoOpen = options.autoOpen ?? true
    this.ackRpcs = options.ackRpcs ?? true
    this.rejectWith = options.rejectWith
    this.interceptor = options.interceptor ?? (() => "deliver")
    this.beforeRpc = options.beforeRpc
    const unsubscribe = transport.onClientMessage((message) => {
      this.enqueue(() => this.handle(message))
    })
    this.detach = () => {
      unsubscribe()
      this.closeSession()
    }
  }

  /** The model session for the current connection, if one is open. */
  get sessionId() {
    return this.session?.id
  }

  /** Wait for frames already accepted from the client to be answered. */
  idle() {
    return this.queue
  }

  dispose() {
    this.detach()
  }

  /** Open the session by hand (when `autoOpen` is off). */
  async openSession() {
    this.ensureSession()
    await this.send({
      kind: "open",
      message: serverMessage({ oneofKind: "connectionOpen", connectionOpen: {} }),
    })
  }

  private enqueue(task: () => Promise<void>) {
    this.queue = this.queue.then(task, task)
  }

  private async handle(message: ClientMessage) {
    switch (message.body.oneofKind) {
      case "connectionInit":
        if (this.rejectWith != null) {
          await this.transport.rejectConnection(this.rejectWith)
          return
        }
        this.closeSession()
        if (this.autoOpen) await this.openSession()
        return
      case "rpcCall": {
        const session = this.ensureSession()
        if (this.ackRpcs) {
          await this.send({
            kind: "ack",
            message: serverMessage({ oneofKind: "ack", ack: { msgId: message.id } }),
          })
        }
        this.beforeRpc?.({
          method: message.body.rpcCall.method,
          input: message.body.rpcCall.input,
        })
        const outcome: RpcOutcome = this.model.handleRpc(
          session.id,
          message.body.rpcCall.method,
          message.body.rpcCall.input,
        )
        // Pushes the model made while answering (discovery hints) were handed
        // to the transport synchronously, so they precede the result.
        await this.send({
          kind: "result",
          message:
            "result" in outcome
              ? serverMessage({
                  oneofKind: "rpcResult",
                  rpcResult: { reqMsgId: message.id, result: outcome.result },
                })
              : serverMessage({
                  oneofKind: "rpcError",
                  rpcError: {
                    reqMsgId: message.id,
                    errorCode: outcome.error.code,
                    message: outcome.error.message,
                    code: 400,
                    retryAfterSeconds: 0,
                  },
                }),
        })
        return
      }
      default:
        return
    }
  }

  private ensureSession(): ModelSession {
    if (this.session && this.sessionConnection === this.transport.connection) {
      return this.session
    }
    this.closeSession()
    this.sessionConnection = this.transport.connection
    this.session = this.model.connect((push) => {
      const connection = this.sessionConnection
      // A push belongs to the connection that was live when it was made.
      void this.send(
        {
          kind: push.kind === "hint" ? "hint" : "push",
          push,
          message: serverMessage({
            oneofKind: "message",
            message: {
              payload: { oneofKind: "update", update: { updates: push.updates } },
            },
          }),
        },
        connection,
      )
    })
    return this.session
  }

  private closeSession() {
    this.session?.close()
    this.session = undefined
    this.sessionConnection = -1
  }

  private async send(frame: OutgoingFrame, connection = this.transport.connection) {
    if (
      connection !== this.transport.connection ||
      this.transport.state !== "connected"
    ) {
      // The socket this frame was meant for is gone; so is its session.
      this.transport.lost.push({ message: frame.message, connection })
      if (this.sessionConnection !== this.transport.connection) this.closeSession()
      return
    }
    const decision = this.interceptor(frame)
    switch (decision) {
      case "deliver":
        await this.transport.deliver(frame.message)
        return
      case "duplicate":
        await this.transport.deliver(frame.message)
        await this.transport.deliver(frame.message)
        return
      case "drop":
        this.dropped.push(frame)
        this.transport.lost.push({ message: frame.message, connection })
        return
      case "deliver-then-disconnect":
        await this.transport.deliver(frame.message)
        this.closeSession()
        await this.transport.disconnect("scripted-connection-loss")
        return
      case "drop-and-disconnect":
        this.dropped.push(frame)
        this.transport.lost.push({ message: frame.message, connection })
        this.closeSession()
        await this.transport.disconnect("scripted-connection-loss")
        return
    }
  }
}
