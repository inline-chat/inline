import {
  ClientMessage,
  Method,
  PushNotificationProvider,
  ServerProtocolMessage,
  type RpcCall,
  type RpcResult,
} from "@inline-chat/protocol/core"

import { appConfig } from "@/config/app"
import { createLogger } from "@/observability/logger"

type PendingRpc = {
  resolve: (result: RpcResult["result"]) => void
  reject: (error: Error) => void
  timer: ReturnType<typeof setTimeout>
}

export class RealtimeClient {
  private socket: WebSocket | null = null
  private seq = 0
  private idCounter = 0
  private pending = new Map<bigint, PendingRpc>()
  private openPromise: Promise<void> | null = null
  private readonly log = createLogger("realtime")

  constructor(private readonly token: string) {}

  async updateAndroidPushToken(expoPushToken: string): Promise<void> {
    await this.connect()
    const result = await this.call(Method.UPDATE_PUSH_NOTIFICATION_DETAILS, {
      oneofKind: "updatePushNotificationDetails",
      updatePushNotificationDetails: {
        applePushToken: "",
        notificationMethod: {
          provider: PushNotificationProvider.EXPO_ANDROID,
          method: {
            oneofKind: "expoAndroid",
            expoAndroid: {
              expoPushToken,
            },
          },
        },
      },
    })

    if (result.oneofKind !== "updatePushNotificationDetails") {
      throw new Error(`Unexpected push registration result: ${String(result.oneofKind)}`)
    }
  }

  close() {
    this.rejectPending(new Error("Realtime connection closed"))
    this.socket?.close()
    this.socket = null
    this.openPromise = null
  }

  private connect(): Promise<void> {
    if (this.openPromise) return this.openPromise

    this.openPromise = new Promise((resolve, reject) => {
      const socket = new WebSocket(appConfig.apiWsUrl)
      this.socket = socket
      socket.binaryType = "arraybuffer"
      let settled = false

      const timeout = setTimeout(() => {
        fail(new Error("Realtime connection timed out"))
      }, 15_000)

      const succeed = () => {
        if (settled) return
        settled = true
        clearTimeout(timeout)
        this.log.debug("Connected")
        resolve()
      }

      const fail = (error: Error) => {
        if (settled) return
        settled = true
        clearTimeout(timeout)
        this.openPromise = null
        this.log.error("Connection failed", error)
        reject(error)
        socket.close()
      }

      socket.onopen = () => {
        this.send({
          oneofKind: "connectionInit",
          connectionInit: {
            token: this.token,
            layer: 2,
            clientVersion: appConfig.version,
          },
        })
      }

      socket.onmessage = async (event) => {
        try {
          const message = ServerProtocolMessage.fromBinary(await eventBytes(event.data))
          switch (message.body.oneofKind) {
            case "connectionOpen":
              succeed()
              break
            case "connectionError":
              fail(new Error(`Realtime auth failed: ${message.body.connectionError.reason}`))
              break
            case "rpcResult":
              this.resolveRpc(message.body.rpcResult.reqMsgId, message.body.rpcResult.result)
              break
            case "rpcError":
              this.rejectRpc(
                message.body.rpcError.reqMsgId,
                new Error(message.body.rpcError.message || "Realtime RPC failed"),
              )
              break
          }
        } catch (error) {
          fail(error instanceof Error ? error : new Error("Failed to parse realtime message"))
        }
      }

      socket.onerror = () => {
        fail(new Error("Realtime socket failed"))
      }

      socket.onclose = () => {
        clearTimeout(timeout)
        this.socket = null
        this.openPromise = null
        if (!settled) {
          fail(new Error("Realtime socket closed before authentication"))
        }
        this.rejectPending(new Error("Realtime socket closed"))
      }
    })

    return this.openPromise
  }

  private call(method: Method, input: RpcCall["input"]): Promise<RpcResult["result"]> {
    const message = this.send({
      oneofKind: "rpcCall",
      rpcCall: {
        method,
        input,
      },
    })

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(message.id)
        reject(new Error("Realtime RPC timed out"))
      }, 15_000)
      this.pending.set(message.id, { resolve, reject, timer })
    })
  }

  private send(body: ClientMessage["body"]): ClientMessage {
    const socket = this.socket
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      throw new Error("Realtime socket is not open")
    }

    const message = ClientMessage.create({
      id: this.nextId(),
      seq: this.nextSeq(),
      body,
    })
    const bytes = ClientMessage.toBinary(message)
    socket.send(toArrayBuffer(bytes))
    return message
  }

  private resolveRpc(id: bigint, result: RpcResult["result"]) {
    const pending = this.pending.get(id)
    if (!pending) return
    this.pending.delete(id)
    clearTimeout(pending.timer)
    pending.resolve(result)
  }

  private rejectRpc(id: bigint, error: Error) {
    const pending = this.pending.get(id)
    if (!pending) return
    this.pending.delete(id)
    clearTimeout(pending.timer)
    pending.reject(error)
  }

  private rejectPending(error: Error) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer)
      pending.reject(error)
    }
    this.pending.clear()
  }

  private nextSeq(): number {
    this.seq = (this.seq + 1) >>> 0
    return this.seq
  }

  private nextId(): bigint {
    this.idCounter = (this.idCounter + 1) >>> 0
    return BigInt(Date.now()) * 1000n + BigInt(this.idCounter)
  }
}

async function eventBytes(data: unknown): Promise<Uint8Array> {
  if (data instanceof ArrayBuffer) return new Uint8Array(data)
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
  if (data && typeof data === "object" && "arrayBuffer" in data) {
    return new Uint8Array(await (data as Blob).arrayBuffer())
  }
  throw new Error("Unsupported realtime payload")
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.byteLength)
  copy.set(bytes)
  return copy.buffer
}
