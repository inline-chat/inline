import { createHash, randomUUID } from "node:crypto"
import { request } from "node:https"
import { isIP } from "node:net"
import { checkServerIdentity } from "node:tls"
import { parseArgs } from "node:util"
import { ClientMessage, ServerProtocolMessage, UpdatesPayload } from "@inline-chat/protocol/core"

const HOST = "api.inline.chat"
const BOT_USERNAME = "inline_release_smoke_bot"
const CHAT_TITLE = "Inline Release Smoke"
const MAX_RESPONSE_BYTES = 2 * 1024 * 1024
const TEXT_BYTES = 20_100
const object = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value)
const positiveId = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value) && value > 0

type Origin = { name: string; ip: string }
type Api = (ip: string, path: string, token?: string, body?: unknown) => Promise<Record<string, unknown>>
type ProbeSocket = WebSocket & { terminate(): void }
type SocketFactory = (ip: string) => ProbeSocket
// lib.dom omits Bun's client TLS options and terminate(). This command runs on
// the same pinned Bun runtime as the qualified image.
export const NativeWebSocket = globalThis.WebSocket as unknown as {
  new(url: string, options?: Bun.WebSocketOptions): ProbeSocket
}
export type CrossOriginOptions = {
  revision?: string
  flyIp: string
  nbgIp: string
  token: string
  chatId: string
  performWrites?: boolean
  timeoutMs?: number
  api?: Api
  createSocket?: SocketFactory
}

export const originApi: Api = (ip, path, token, body) => new Promise((resolve, reject) => {
  const encoded = body === undefined ? undefined : JSON.stringify(body)
  const req = request({
    hostname: ip, port: 443, servername: HOST, path, method: encoded ? "POST" : "GET",
    rejectUnauthorized: true,
    checkServerIdentity: (_hostname, certificate) => checkServerIdentity(HOST, certificate),
    headers: { Host: HOST, ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(encoded ? { "content-type": "application/json", "content-length": String(Buffer.byteLength(encoded)) } : {}) },
  }, (response) => {
    const chunks: Buffer[] = []
    let size = 0
    response.on("data", (chunk: Buffer) => {
      size += chunk.byteLength
      if (size > MAX_RESPONSE_BYTES) req.destroy(new Error("Origin response exceeded its byte budget"))
      else chunks.push(chunk)
    })
    response.on("error", () => reject(new Error("Origin response failed")))
    response.on("end", () => {
      if (response.statusCode !== 200) return reject(new Error(`Origin returned HTTP ${response.statusCode ?? 0}`))
      try {
        const value: unknown = JSON.parse(Buffer.concat(chunks).toString("utf8"))
        if (!object(value) || value["ok"] !== true) throw new Error()
        resolve(value)
      } catch { reject(new Error("Origin returned an invalid successful response")) }
    })
  })
  req.setTimeout(15_000, () => req.destroy(new Error("Origin request timed out")))
  // Provider causes can include URLs or headers; return a fixed classification.
  req.on("error", () => reject(new Error("Origin request failed")))
  req.end(encoded)
})

export function originSocketTarget(ip: string) {
  if (!isIP(ip)) throw new Error("A valid origin IP is required")
  return { url: `wss://${isIP(ip) === 6 ? `[${ip}]` : ip}/realtime`, options: {
    headers: { Host: HOST }, tls: { serverName: HOST, rejectUnauthorized: true },
  } }
}
export const originSocket: SocketFactory = (ip) => {
  const target = originSocketTarget(ip)
  return new NativeWebSocket(target.url, target.options)
}

const bounded = async <T>(work: Promise<T>, milliseconds: number, label: string): Promise<T> => {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([work, new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => reject(new Error(label)), milliseconds)
    })])
  } finally { clearTimeout(timer) }
}

async function preflight(origin: Origin, options: CrossOriginOptions, api: Api): Promise<number> {
  const ready = await api(origin.ip, "/readyz")
  if (typeof ready["revision"] !== "string" || !/^[a-f0-9]{40}$/.test(ready["revision"]) ||
    (options.revision && ready["revision"] !== options.revision) || ready["draining"] !== false) {
    throw new Error(`${origin.name} is not ready on the selected revision`)
  }
  const me = await api(origin.ip, "/bot/getMe", options.token)
  const user = object(me["result"]) && object(me["result"]["user"]) ? me["result"]["user"] : undefined
  if (!user || !positiveId(user["id"]) || user["is_bot"] !== true || user["username"] !== BOT_USERNAME) {
    throw new Error("Credential does not identify the dedicated release smoke bot")
  }
  const response = await api(origin.ip, `/bot/getChat?chat_id=${options.chatId}`, options.token)
  const chat = object(response["result"]) && object(response["result"]["chat"]) ? response["result"]["chat"] : undefined
  if (!chat || chat["chat_id"] !== Number(options.chatId) || chat["type"] !== "thread" || chat["title"] !== CHAT_TITLE ||
    chat["space_id"] != null || chat["is_public"] === true) throw new Error("Target is not the private release smoke fixture")
  return user["id"]
}

type LiveReceipt = { messageId: bigint; textBytes: number; updatesBytes: number; frameBytes: number }
async function direction(send: Origin, receive: Origin, botId: number, options: CrossOriginOptions, api: Api, createSocket: SocketFactory) {
  if (!options.revision) throw new Error("A full release revision is required before sending")
  const marker = `Release verification: ${send.name} to ${receive.name} ${options.revision.slice(0, 9)} ${randomUUID()}\n`
  const text = marker + "x".repeat(TEXT_BYTES - Buffer.byteLength(marker))
  const authenticated = Promise.withResolvers<void>()
  const delivered = Promise.withResolvers<LiveReceipt>()
  // Socket failures can precede the corresponding await.
  void authenticated.promise.catch(() => undefined)
  void delivered.promise.catch(() => undefined)
  const socket = createSocket(receive.ip)
  const closed = Promise.withResolvers<void>()
  socket.binaryType = "arraybuffer"
  let disposing = false
  let seq = 0
  let clientMessageId = 0n
  const fail = (message: string) => {
    const error = new Error(message)
    authenticated.reject(error)
    delivered.reject(error)
  }
  socket.addEventListener("open", () => {
    // Layer one also permits the HTTP sender's own session to receive its push.
    // Only this receiver is connected; no RPC or GET_UPDATES is ever issued.
    socket.send(Uint8Array.from(ClientMessage.toBinary({ id: ++clientMessageId, seq: ++seq, body: { oneofKind: "connectionInit", connectionInit: {
      token: options.token, layer: 1,
    } } })).buffer)
  }, { once: true })
  socket.addEventListener("error", () => { if (!disposing) fail("Receiver WebSocket failed") })
  socket.addEventListener("close", () => { closed.resolve(); if (!disposing) fail("Receiver closed before verification completed") })
  socket.addEventListener("message", ({ data }) => {
    try {
      if (!(data instanceof ArrayBuffer) || data.byteLength > MAX_RESPONSE_BYTES) throw new Error()
      const frame = ServerProtocolMessage.fromBinary(new Uint8Array(data))
      if (frame.body.oneofKind === "connectionOpen") authenticated.resolve()
      if (frame.body.oneofKind === "connectionError" || frame.body.oneofKind === "rpcError") throw new Error()
      if (frame.body.oneofKind !== "message" || frame.body.message.payload.oneofKind !== "update") return
      for (const update of frame.body.message.payload.update.updates) {
        if (update.update.oneofKind !== "newMessage") continue
        const message = update.update.newMessage.message
        if (!message || message.chatId !== BigInt(options.chatId) || message.fromId !== BigInt(botId) || message.message !== text) continue
        const updatesBytes = UpdatesPayload.toBinary({ updates: [update] }).byteLength
        if (updatesBytes <= 20_000) throw new Error()
        delivered.resolve({ messageId: message.id, textBytes: Buffer.byteLength(text), updatesBytes, frameBytes: data.byteLength })
      }
    } catch { fail("Receiver protocol or payload verification failed") }
  })
  try {
    await bounded(authenticated.promise, options.timeoutMs ?? 15_000, "Receiver authentication timed out")
    const started = Date.now()
    // Exactly one send. A failure after dispatch is ambiguous and never retried.
    let sent: Record<string, unknown>
    try {
      sent = await api(send.ip, "/bot/sendMessage", options.token, {
        chat_id: Number(options.chatId), text, parse_markdown: false, silent: true,
      })
    } catch { throw new Error("Send outcome is ambiguous; inspect the smoke chat before retrying") }
    const message = object(sent["result"]) && object(sent["result"]["message"]) ? sent["result"]["message"] : undefined
    if (!message || !positiveId(message["message_id"])) throw new Error("Send outcome is ambiguous; inspect the smoke chat before retrying")
    const receipt = await bounded(delivered.promise, options.timeoutMs ?? 15_000,
      `No full cross-origin push for message ${message["message_id"]}; message remains in the smoke chat`)
    if (receipt.messageId !== BigInt(message["message_id"])) throw new Error("Live message identity did not match the send receipt")
    return { direction: `${send.name}->${receive.name}`, messageId: message["message_id"], chatId: Number(options.chatId),
      textBytes: receipt.textBytes, updatesBytes: receipt.updatesBytes, frameBytes: receipt.frameBytes,
      textSha256: createHash("sha256").update(text).digest("hex"), elapsedMs: Date.now() - started,
      unsolicitedLivePush: true, getUpdatesRequests: 0 }
  } finally {
    disposing = true
    if (socket.readyState !== WebSocket.CLOSED) socket.close()
    try { await bounded(closed.promise, 1_000, "Receiver cleanup timed out") }
    catch { socket.terminate() }
  }
}

export async function crossOriginSmoke(options: CrossOriginOptions) {
  if ((options.performWrites || options.revision !== undefined) && !/^[a-f0-9]{40}$/.test(options.revision ?? "")) {
    throw new Error("A full release revision is required")
  }
  if (!isIP(options.flyIp) || !isIP(options.nbgIp) || options.flyIp === options.nbgIp) throw new Error("Two distinct origin IPs are required")
  if (!options.token || /[\r\n]/.test(options.token) || !/^[1-9]\d*$/.test(options.chatId) || !positiveId(Number(options.chatId))) {
    throw new Error("SMOKE_BOT_TOKEN and a valid SMOKE_CHAT_ID are required")
  }
  const api = options.api ?? originApi
  const createSocket = options.createSocket ?? originSocket
  const fly = { name: "fly", ip: options.flyIp }
  const nbg = { name: "nuremberg", ip: options.nbgIp }
  const flyBot = await preflight(fly, options, api)
  const nbgBot = await preflight(nbg, options, api)
  if (flyBot !== nbgBot) throw new Error("Origins authenticated different release bots")
  if (!options.performWrites) return { revision: options.revision, botId: flyBot, preflight: true, deliveries: [] }
  const deliveries = []
  for (const [send, receive] of [[fly, nbg], [nbg, fly]] as const) {
    deliveries.push(await direction(send, receive, flyBot, options, api, createSocket))
  }
  return { revision: options.revision, botId: flyBot, preflight: false, deliveries }
}

export async function main(args = process.argv.slice(2)): Promise<number> {
  const { values } = parseArgs({ args, options: {
    revision: { type: "string" }, "fly-ip": { type: "string" }, "nbg-ip": { type: "string" },
    preflight: { type: "boolean" }, "confirm-test-writes": { type: "boolean" }, help: { type: "boolean" },
  } })
  if (values.help) {
    console.log("Usage: realtime-cross-origin-smoke --fly-ip IP --nbg-ip IP [--preflight | --revision SHA --confirm-test-writes]")
    return 0
  }
  if (Boolean(values.preflight) === Boolean(values["confirm-test-writes"])) throw new Error("Choose --preflight or --confirm-test-writes")
  const report = await crossOriginSmoke({ revision: values.revision, flyIp: values["fly-ip"] ?? "", nbgIp: values["nbg-ip"] ?? "",
    token: process.env["SMOKE_BOT_TOKEN"] ?? "", chatId: process.env["SMOKE_CHAT_ID"] ?? "", performWrites: values["confirm-test-writes"] })
  console.log(JSON.stringify(report))
  return 0
}

if (import.meta.main) {
  try { process.exitCode = await main() }
  catch (error) { console.error(error instanceof Error ? error.message : "Cross-origin qualification failed"); process.exitCode = 1 }
}
