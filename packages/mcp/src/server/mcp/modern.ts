import { Buffer } from "node:buffer"
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import type { AuthInfo } from "@modelcontextprotocol/sdk/server/auth/types.js"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import {
  JSONRPCRequestSchema,
  SUPPORTED_PROTOCOL_VERSIONS,
  type JSONRPCMessage,
  type JSONRPCRequest,
  type JSONRPCResponse,
} from "@modelcontextprotocol/sdk/types.js"
import { EventsRpcError, type EventsProxy } from "./events-proxy"

export const MODERN_MCP_VERSION = "2026-07-28"
const VERSION_KEY = "io.modelcontextprotocol/protocolVersion"
const CAPABILITIES_KEY = "io.modelcontextprotocol/clientCapabilities"
const SERVER_INFO_KEY = "io.modelcontextprotocol/serverInfo"
const LEGACY_VERSIONS = new Set(SUPPORTED_PROTOCOL_VERSIONS)
const SDK_METHODS = new Set(["tools/list", "tools/call", "resources/list", "resources/templates/list", "resources/read"])
const EVENT_METHODS = new Set(["events/list", "events/subscribe", "events/unsubscribe"])
const MAX_REQUEST_BYTES = 40 * 1024 * 1024 // Covers the existing 25 MiB base64 upload tool.

function record(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function rpcError(id: string | number | undefined, code: number, message: string, status = 400, data?: unknown): Response {
  return Response.json({ jsonrpc: "2.0", ...(id === undefined ? {} : { id }), error: { code, message, ...(data === undefined ? {} : { data }) } }, { status })
}

function complete(value: Record<string, unknown>): Record<string, unknown> {
  return {
    ...value,
    resultType: "complete",
    _meta: {
      ...(record(value._meta) ? value._meta : {}),
      [SERVER_INFO_KEY]: { name: "inline", version: "0.3.0", title: "Inline" },
    },
  }
}

/** Strict decoding prevents ambiguous/noncanonical encodings from bypassing header policy. */
function decodeNameHeader(value: string): string | null {
  const sentinel = /^=\?base64\?([A-Za-z0-9+/]*={0,2})\?=$/.exec(value)
  if (value.startsWith("=?base64?")) {
    if (!sentinel) return null
    const bytes = Buffer.from(sentinel[1]!, "base64")
    if (bytes.toString("base64") !== sentinel[1]) return null
    try { return new TextDecoder("utf-8", { fatal: true }).decode(bytes) } catch { return null }
  }
  for (const character of value) {
    const code = character.charCodeAt(0)
    if (code !== 9 && (code < 32 || code > 126)) return null
  }
  return value.trim() === value ? value : null
}

class RequestTooLargeError extends EventsRpcError {
  constructor() { super(-32600, "MCP request is too large") }
}

async function readBody(req: Request): Promise<unknown> {
  if (!req.body) throw new EventsRpcError(-32700, "Missing JSON request")
  const declaredLength = req.headers.get("content-length")
  if (declaredLength && /^\d+$/.test(declaredLength) && Number(declaredLength) > MAX_REQUEST_BYTES) {
    throw new RequestTooLargeError()
  }
  const reader = req.body.getReader()
  let size = 0
  const chunks: Uint8Array[] = []
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      size += value.byteLength
      if (size > MAX_REQUEST_BYTES) {
        await reader.cancel()
        throw new RequestTooLargeError()
      }
      chunks.push(value)
    }
    const bytes = Buffer.concat(chunks, size)
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)) as unknown
  } catch (error) {
    if (error instanceof EventsRpcError) throw error
    throw new EventsRpcError(-32700, "Invalid JSON request")
  } finally { reader.releaseLock() }
}

/** Valid modern requests identify their lane without reading unauthenticated bodies. */
export function modernRequestHeaderHint(req: Request): boolean | undefined {
  const version = req.headers.get("mcp-protocol-version")
  if (version && !LEGACY_VERSIONS.has(version)) return true
  if (req.method !== "POST") return false
  const method = req.headers.get("mcp-method")
  if (method === "server/discover" || method?.startsWith("events/")) return true
  // Older clients do not include these headers. A malformed modern request must
  // get its modern protocol error rather than accidentally initialize a session.
  if (!version && (method || req.headers.has("mcp-name"))) return true
  return undefined
}

/** Identify modern traffic before considering legacy session headers. */
export async function isModernRequest(req: Request): Promise<boolean> {
  const hint = modernRequestHeaderHint(req)
  if (hint !== undefined) return hint
  try {
    const body = await readBody(req.clone())
    if (!record(body)) return false
    const meta = record(body.params) && record(body.params._meta) ? body.params._meta : null
    return body.method === "server/discover" || (typeof body.method === "string" && body.method.startsWith("events/")) ||
      (meta !== null && (VERSION_KEY in meta || CAPABILITIES_KEY in meta))
  } catch { return false }
}

/** Adapt existing SDK handlers through its public Transport API, with no duplicate tool registry. */
class RequestTransport implements Transport {
  onclose?: () => void
  onerror?: (error: Error) => void
  onmessage?: Transport["onmessage"]
  private closed = false
  private pending?: {
    id: string | number
    resolve: (message: JSONRPCResponse) => void
    reject: (error: Error) => void
  }
  async start(): Promise<void> {}
  async send(message: JSONRPCMessage): Promise<void> {
    if (this.closed) return
    if ("result" in message || "error" in message) {
      const pending = this.pending
      if (!pending || message.id !== pending.id) throw new Error("Unexpected MCP response ID")
      this.pending = undefined
      pending.resolve(message)
    } else if ("id" in message) {
      // The adapter does not advertise MRTR or sampling. Legacy SDK callbacks
      // must never emit standalone server requests on this HTTP response.
      throw new Error("Server-to-client requests are unavailable for this request")
    }
  }
  async close(): Promise<void> {
    if (this.closed) return
    this.closed = true
    this.pending?.reject(new Error("MCP request transport closed"))
    this.pending = undefined
    this.onclose?.()
  }
  request(message: JSONRPCRequest, auth: AuthInfo, req: Request): Promise<JSONRPCResponse> {
    return new Promise((resolve, reject) => {
      if (this.closed || this.pending || !this.onmessage) {
        reject(new Error("MCP request transport is unavailable"))
        return
      }
      this.pending = { id: message.id, resolve, reject }
      try {
        this.onmessage(message, {
          authInfo: auth,
          requestInfo: { headers: Object.fromEntries(req.headers), url: new URL(req.url) },
        })
      } catch (error) {
        this.pending = undefined
        reject(error instanceof Error ? error : new Error("MCP dispatch failed"))
      }
    })
  }
}

function validClientCapabilities(value: unknown): value is Record<string, unknown> {
  if (!record(value)) return false
  for (const key of ["roots", "sampling", "elicitation", "experimental", "extensions"]) {
    if (value[key] !== undefined && !record(value[key])) return false
  }
  for (const key of ["experimental", "extensions"]) {
    const settings = value[key]
    if (record(settings) && Object.values(settings).some((entry) => !record(entry))) return false
  }
  for (const [key, subkeys] of [["sampling", ["context", "tools"]], ["elicitation", ["form", "url"]]] as const) {
    const settings = value[key]
    if (record(settings) && subkeys.some((subkey) => settings[subkey] !== undefined && !record(settings[subkey]))) return false
  }
  return true
}

/** Validate any future mirrored tool parameters using the SDK's public descriptor. */
function validateToolHeaders(schema: unknown, args: unknown, headers: Headers): boolean {
  if (!record(schema) || !record(schema.properties)) return true
  for (const [key, property] of Object.entries(schema.properties)) {
    if (!record(property)) continue
    const value = record(args) ? args[key] : undefined
    const headerName = property["x-mcp-header"]
    if (typeof headerName === "string") {
      const header = headers.get(`mcp-param-${headerName}`)
      if (value === null || value === undefined) {
        if (header !== null) return false
      } else {
        if (header === null) return false
        const decoded = decodeNameHeader(header)
        if (typeof value === "number" && Number.isSafeInteger(value)) {
          if (decoded === null || decoded.trim() === "" || Number(decoded) !== value) return false
        } else if ((typeof value !== "string" && typeof value !== "boolean") || decoded !== String(value)) return false
      }
    }
    if (!validateToolHeaders(property, value, headers)) return false
  }
  return true
}

export async function handleModernRequest(params: {
  req: Request
  auth: AuthInfo
  events: EventsProxy
  createServer: () => McpServer
  instructions: string
}): Promise<Response> {
  const { req } = params
  if (req.method !== "POST") return new Response(null, { status: 405, headers: { allow: "POST" } })
  let body: unknown
  try { body = await readBody(req) } catch (error) {
    return rpcError(undefined, error instanceof EventsRpcError ? error.code : -32700, error instanceof Error ? error.message : "Invalid request", error instanceof RequestTooLargeError ? 413 : 400)
  }
  const parsed = JSONRPCRequestSchema.safeParse(body)
  if (!parsed.success) {
    const id = record(body) && (typeof body.id === "string" || (typeof body.id === "number" && Number.isInteger(body.id))) ? body.id : undefined
    return rpcError(id, -32600, "Expected one JSON-RPC request with an ID")
  }
  const request = parsed.data
  const id = request.id
  const meta = record(request.params) && record(request.params._meta) ? request.params._meta : null
  if (!meta || typeof meta[VERSION_KEY] !== "string" || !validClientCapabilities(meta[CAPABILITIES_KEY])) {
    return rpcError(id, -32602, "Every request requires protocol version and client capabilities in params._meta")
  }
  const clientInfo = meta["io.modelcontextprotocol/clientInfo"]
  if (clientInfo !== undefined && (!record(clientInfo) || typeof clientInfo.name !== "string" || typeof clientInfo.version !== "string")) {
    return rpcError(id, -32602, "Client information must include name and version strings")
  }
  const logLevel = meta["io.modelcontextprotocol/logLevel"]
  if (logLevel !== undefined && (typeof logLevel !== "string" || !["debug", "info", "notice", "warning", "error", "critical", "alert", "emergency"].includes(logLevel))) {
    return rpcError(id, -32602, "Invalid client log level")
  }
  const version = meta[VERSION_KEY]
  const headerVersion = req.headers.get("mcp-protocol-version")
  if (!headerVersion || headerVersion !== version || req.headers.get("mcp-method") !== request.method) {
    return rpcError(id, -32020, "Required MCP headers are missing or do not match the request")
  }
  if (version !== MODERN_MCP_VERSION) {
    return rpcError(id, -32022, "Unsupported protocol version", 400, { supported: [MODERN_MCP_VERSION], requested: version })
  }
  if (request.method === "tools/call" || request.method === "resources/read" || request.method === "prompts/get") {
    const source = request.method === "resources/read" ? request.params?.uri : request.params?.name
    const name = req.headers.get("mcp-name")
    if (typeof source !== "string" || name === null || decodeNameHeader(name) !== source) {
      return rpcError(id, -32020, "Mcp-Name header is missing or does not match the request")
    }
  }
  if (request.method === "server/discover") {
    return Response.json({ jsonrpc: "2.0", id, result: complete({
      supportedVersions: [MODERN_MCP_VERSION], capabilities: { tools: {}, resources: {}, events: {} },
      instructions: params.instructions,
    }) })
  }
  if (EVENT_METHODS.has(request.method)) {
    try {
      const result = await params.events.request(request.method, request.params ?? {})
      return Response.json({ jsonrpc: "2.0", id, result: complete(result) })
    } catch (error) {
      return error instanceof EventsRpcError
        ? rpcError(id, error.code, error.message, error.code === -32603 ? 502 : 400, error.data)
        : rpcError(id, -32603, "Events request failed", 502)
    }
  }
  if (!SDK_METHODS.has(request.method)) return rpcError(id, -32601, "Method not found", 404)
  if (request.params && ["inputResponses", "requestState", "task"].some((key) => key in request.params!)) {
    return rpcError(id, -32602, "This method does not support request continuation or task augmentation")
  }
  const transport = new RequestTransport()
  let server: McpServer | undefined
  const signal = AbortSignal.any([req.signal, AbortSignal.timeout(90_000)])
  let rejectAborted!: (reason?: unknown) => void
  const aborted = new Promise<never>((_resolve, reject) => { rejectAborted = reject })
  // Cancellation can arrive while connect() is still running, before the race.
  void aborted.catch(() => undefined)
  const onAbort = () => rejectAborted(new EventsRpcError(-32603, "Request interrupted; confirm any write outcome before retrying"))
  signal.addEventListener("abort", onAbort, { once: true })
  try {
    if (signal.aborted) return rpcError(id, -32603, "Request interrupted before execution", 500)
    server = params.createServer()
    await server.connect(transport)
    if (signal.aborted) return rpcError(id, -32603, "Request interrupted before execution", 500)
    if (request.method === "tools/call") {
      // The legacy SDK wraps unknown tool names as tool errors. Modern MCP
      // requires a protocol error; obtain descriptors through the public RPC.
      const list = await Promise.race([
        transport.request({ jsonrpc: "2.0", id, method: "tools/list", params: { _meta: meta } }, params.auth, req),
        aborted,
      ])
      if ("error" in list) return Response.json(list, { status: list.error.code === -32601 ? 404 : 500 })
      const tools = Array.isArray(list.result.tools) ? list.result.tools : []
      const tool: unknown = tools.find((entry: unknown) => record(entry) && entry.name === request.params?.name)
      if (!record(tool)) return rpcError(id, -32602, "Unknown tool")
      if (!validateToolHeaders(tool.inputSchema, request.params?.arguments, req.headers)) {
        return rpcError(id, -32020, "Mirrored tool parameter headers are missing or do not match the request")
      }
    }
    const message = await Promise.race([transport.request(request, params.auth, req), aborted])
    if ("result" in message) {
      return Response.json({ ...message, result: complete(message.result) })
    }
    if ("error" in message) {
      // Reserved codes removed in July28 must not escape from a legacy SDK.
      const error = message.error.code === -32002
        ? { ...message.error, code: -32602 }
        : message.error.code === -32042
          ? { ...message.error, code: -32603 }
          : message.error
      return Response.json({ ...message, error }, { status: error.code === -32601 ? 404 : error.code === -32603 ? 500 : 400 })
    }
    return rpcError(id, -32603, "Unexpected server response", 500)
  } catch (error) {
    return rpcError(id, -32603, error instanceof EventsRpcError ? error.message : "MCP request failed", 500)
  } finally {
    signal.removeEventListener("abort", onAbort)
    if (server) {
      await server.close().catch(async () => { await transport.close() })
    }
  }
}
