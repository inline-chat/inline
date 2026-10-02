import { lookup } from "node:dns/promises"
import { isIP } from "node:net"
import { request as httpsRequest, type RequestOptions } from "node:https"
import type { ClientRequest, IncomingMessage } from "node:http"
import { randomBytes } from "node:crypto"
import { sameSecret, signature } from "./crypto"
import { McpEventsError, invalidParams } from "./types"

const callbackFailure = (reason: string) => new McpEventsError({ code: -32015, message: "Callback endpoint could not be verified", reason })
export const MAX_EVENT_BYTES = 256 * 1024

/** Conservative public-unicast allowlist, including hexadecimal IPv4-mapped IPv6. */
export function isPublicAddress(address: string): boolean {
  if (address.includes("%")) return false
  if (isIP(address) === 4) {
    const [a, b, c] = address.split(".").map(Number)
    if (a === undefined || b === undefined || c === undefined) return false
    return !(a === 0 || a === 10 || a === 127 || a >= 224 ||
      (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) || (a === 192 && (b === 0 || b === 168 || (b === 88 && c === 99))) ||
      (a === 198 && (b === 18 || b === 19 || (b === 51 && c === 100))) || (a === 203 && b === 0 && c === 113))
  }
  if (isIP(address) !== 6) return false
  const text = address.toLowerCase()
  const segments = text.split("::")
  const read = (part: string): number[] => part === "" ? [] : part.split(":").flatMap((word) => {
    if (!word.includes(".")) return [Number.parseInt(word, 16)]
    const bytes = word.split(".").map(Number)
    return [(bytes[0]! << 8) | bytes[1]!, (bytes[2]! << 8) | bytes[3]!]
  })
  const left = read(segments[0] ?? "")
  const right = read(segments[1] ?? "")
  const words = segments.length === 2 ? [...left, ...Array<number>(8 - left.length - right.length).fill(0), ...right] : left
  if (words.length !== 8) return false
  if (words.slice(0, 5).every((word) => word === 0) && words[5] === 0xffff) {
    return isPublicAddress(`${words[6]! >>> 8}.${words[6]! & 255}.${words[7]! >>> 8}.${words[7]! & 255}`)
  }
  const first = words[0]!
  const second = words[1]!
  return (first & 0xe000) === 0x2000 && first !== 0x2002 &&
    !(first === 0x2001 && (second < 0x200 || second === 0xdb8)) &&
    !(first === 0x3fff && (second & 0xf000) === 0)
}

export function callbackUrl(raw: unknown): URL {
  if (typeof raw !== "string" || raw.length > 4096) throw invalidParams()
  let url: URL
  try { url = new URL(raw) } catch { throw invalidParams() }
  if (url.protocol !== "https:" || !url.hostname || url.username || url.password || url.hash ||
    (url.port !== "" && url.port !== "443" && url.port !== "8443")) throw invalidParams()
  return url
}

export async function resolveCallback(raw: string): Promise<{ url: URL; address: string; family: 4 | 6 }> {
  const url = callbackUrl(raw)
  const hostname = url.hostname.replace(/^\[|\]$/g, "")
  const family = isIP(hostname)
  let deadline: ReturnType<typeof setTimeout> | undefined
  const addresses = family === 4 || family === 6 ? [{ address: hostname, family }] : await Promise.race([
    lookup(hostname, { all: true, verbatim: true }).catch(() => { throw callbackFailure("connection_refused") }),
    new Promise<never>((_resolve, reject) => { deadline = setTimeout(() => reject(callbackFailure("timeout")), 10_000) }),
  ]).finally(() => { if (deadline) clearTimeout(deadline) })
  if (addresses.length === 0 || addresses.some((value) => !isPublicAddress(value.address))) throw invalidParams()
  const selected = addresses[0]!
  return { url, address: selected.address, family: selected.family as 4 | 6 }
}

type CallbackTarget = Awaited<ReturnType<typeof resolveCallback>>
export type CallbackResponse = { status: number; body: string; retryAfter?: string }
export type CallbackTransport = (input: { url: string; body: string; headers: Record<string, string>; beforeConnect?: () => Promise<void>; readResponseBody?: boolean }) => Promise<CallbackResponse>

export function makeCallbackTransport(dependencies: {
  resolve?: (url: string) => Promise<CallbackTarget>
  request?: (url: URL, options: RequestOptions, callback: (response: IncomingMessage) => void) => ClientRequest
} = {}): CallbackTransport {
  return async (input) => {
    if (Buffer.byteLength(input.body) > MAX_EVENT_BYTES) throw invalidParams()
    const target = await (dependencies.resolve ?? resolveCallback)(input.url)
    await input.beforeConnect?.()
    return new Promise<CallbackResponse>((resolve, reject) => {
      // Bun's Node HTTPS shim does not consistently honor a custom lookup.
      // Supply the validated literal address as the socket hostname instead,
      // retaining the original hostname for TLS verification and HTTP routing.
      const request = (dependencies.request ?? httpsRequest)(target.url, {
        method: "POST", agent: false, hostname: target.address, family: target.family,
        servername: isIP(target.url.hostname.replace(/^\[|\]$/g, "")) ? "" : target.url.hostname,
        headers: { ...input.headers, host: target.url.host, "content-length": Buffer.byteLength(input.body).toString() },
      }, (response) => {
        if (!input.readResponseBody) {
          resolve({ status: response.statusCode ?? 0, body: "",
            ...(response.headers["retry-after"] === undefined ? {} : { retryAfter: String(response.headers["retry-after"]) }) })
          response.on("error", () => {})
          response.destroy()
          return
        }
        const chunks: Buffer[] = []
        let bytes = 0
        response.on("data", (chunk: Buffer) => {
          bytes += chunk.byteLength
          if (bytes > 4096) { response.destroy(callbackFailure("challenge_failed")); return }
          chunks.push(chunk)
        })
        response.on("end", () => resolve({ status: response.statusCode ?? 0, body: Buffer.concat(chunks).toString("utf8"),
          ...(response.headers["retry-after"] === undefined ? {} : { retryAfter: String(response.headers["retry-after"]) }) }))
        response.on("error", reject)
      })
      const deadline = setTimeout(() => request.destroy(callbackFailure("timeout")), 10_000)
      request.on("close", () => clearTimeout(deadline))
      request.on("error", reject)
      request.end(input.body)
    })
  }
}

export const callbackTransport = makeCallbackTransport()

export function signedHeaders(id: string, eventId: string, body: string, secret: string, previousSecret?: string): Record<string, string> {
  const seconds = Math.floor(Date.now() / 1000)
  const signatures = [signature(secret, eventId, seconds, body)]
  if (previousSecret) signatures.push(signature(previousSecret, eventId, seconds, body))
  return { "content-type": "application/json", "webhook-id": eventId, "webhook-timestamp": String(seconds),
    "webhook-signature": signatures.join(" "), "x-mcp-subscription-id": id, "user-agent": "InlineMcpEvents/1.0" }
}

export async function verifyCallback(input: { id: string; url: string; secret: string; beforeConnect?: () => Promise<void> }, transport = callbackTransport): Promise<void> {
  const challenge = randomBytes(32).toString("base64url")
  const body = JSON.stringify({ type: "verification", challenge })
  let response: CallbackResponse
  try {
    response = await transport({ url: input.url, body, headers: signedHeaders(input.id, `verification_${randomBytes(16).toString("hex")}`, body, input.secret),
      readResponseBody: true,
      ...(input.beforeConnect === undefined ? {} : { beforeConnect: input.beforeConnect }) })
  } catch (error) {
    if (error instanceof McpEventsError) throw error
    const code = error && typeof error === "object" && "code" in error ? String(error.code) : ""
    throw callbackFailure(/TLS|CERT|SSL/.test(code) ? "tls_error" : "connection_refused")
  }
  let echoed: unknown
  if (response.status >= 400 && response.status < 500) throw callbackFailure("http_4xx")
  if (response.status >= 500) throw callbackFailure("http_5xx")
  try { echoed = JSON.parse(response.body) } catch { throw callbackFailure("challenge_failed") }
  if (response.status < 200 || response.status >= 300 || !echoed || typeof echoed !== "object" ||
    typeof (echoed as Record<string, unknown>)["challenge"] !== "string" || !sameSecret(challenge, String((echoed as Record<string, unknown>)["challenge"]))) throw callbackFailure("challenge_failed")
}
