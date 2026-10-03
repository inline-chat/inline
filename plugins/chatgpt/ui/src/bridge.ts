import { isRecord, readWidgetState, type RecordValue, type WidgetState } from "./contracts"

type OpenAIExtensions = {
  widgetState?: unknown
  toolResponseMetadata?: unknown
  setWidgetState?: (state: WidgetState) => void
}
declare global { interface Window { openai?: OpenAIExtensions } }

class HostRequestError extends Error {
  constructor(readonly rpcError: unknown) { super("Host could not complete the request") }
}

export type HostState = {
  status: "connecting" | "ready" | "failed" | "closed"
  theme?: "light" | "dark"
  canAttachContext: boolean
}

/** One standard MCP Apps connection. No browser credentials or direct API calls. */
export class HostBridge {
  private nextId = 0
  private pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void; timeout: number }>()
  private listeners = new Set<(event: { kind: "state"; state: HostState } | { kind: "result"; result: unknown }) => void>()
  private state: HostState = { status: "connecting", canAttachContext: false }
  private ready: Promise<void> | null = null

  constructor(private readonly hostWindow: Window = window) { hostWindow.addEventListener("message", this.onMessage) }

  get hostState(): HostState { return this.state }
  get widgetState(): WidgetState { return readWidgetState(this.hostWindow.openai?.widgetState) }
  saveWidgetState(state: WidgetState): void {
    try { this.hostWindow.openai?.setWidgetState?.(state) } catch { /* A host snapshot is best effort; Inline remains canonical. */ }
  }
  subscribe(listener: (event: { kind: "state"; state: HostState } | { kind: "result"; result: unknown }) => void): () => void {
    this.listeners.add(listener)
    return () => { this.listeners.delete(listener) }
  }

  initialize(): Promise<void> {
    this.ready ??= this.request("ui/initialize", {
      appInfo: { name: "inline-thread", version: "0.0.1" },
      appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] },
      protocolVersion: "2026-01-26",
    }, 10_000).then((value) => {
      if (!isRecord(value) || value.protocolVersion !== "2026-01-26") throw new Error("Unsupported host protocol")
      this.state = { status: "ready", canAttachContext: isRecord(value.hostCapabilities) && isRecord(value.hostCapabilities.updateModelContext) }
      this.applyContext(value.hostContext)
      this.notify("ui/notifications/initialized", {})
      this.emit({ kind: "state", state: this.state })
    }).catch((error: unknown) => {
      if (this.state.status !== "closed") {
        this.state = { ...this.state, status: "failed" }
        this.emit({ kind: "state", state: this.state })
      }
      throw error
    })
    return this.ready
  }

  async callTool(name: "conversations.open" | "messages.list" | "messages.send", args: RecordValue): Promise<unknown> {
    await this.initialize()
    return this.request("tools/call", { name, arguments: args }, 120_000)
  }

  async attachContext(params: RecordValue): Promise<void> {
    await this.initialize()
    if (!this.state.canAttachContext) throw new Error("Host cannot attach context")
    await this.request("ui/update-model-context", params, 15_000)
  }

  notifySize(width: number, height: number): void {
    if (this.state.status === "ready") this.notify("ui/notifications/size-changed", { width, height })
  }

  dispose(): void {
    if (this.state.status === "closed") return
    this.state = { ...this.state, status: "closed" }
    this.hostWindow.removeEventListener("message", this.onMessage)
    for (const pending of this.pending.values()) {
      this.hostWindow.clearTimeout(pending.timeout)
      pending.reject(new Error("Host closed the thread view"))
    }
    this.pending.clear()
    this.emit({ kind: "state", state: this.state })
    this.listeners.clear()
  }

  private emit(event: Parameters<Parameters<HostBridge["subscribe"]>[0]>[0]): void { for (const listener of this.listeners) listener(event) }
  private notify(method: string, params: RecordValue): void { this.send({ method, params }) }
  private send(message: RecordValue): void { this.hostWindow.parent.postMessage({ jsonrpc: "2.0", ...message }, "*") }
  private request(method: string, params: RecordValue, timeoutMs: number): Promise<unknown> {
    if (this.state.status === "closed" || this.state.status === "failed") return Promise.reject(new Error("Host unavailable"))
    return new Promise((resolve, reject) => {
      const id = ++this.nextId
      const timeout = this.hostWindow.setTimeout(() => {
        this.pending.delete(id)
        reject(new Error("Host response timed out"))
      }, timeoutMs)
      this.pending.set(id, { resolve, reject, timeout })
      try { this.send({ id, method, params }) } catch {
        this.hostWindow.clearTimeout(timeout)
        this.pending.delete(id)
        reject(new Error("Host unavailable"))
      }
    })
  }

  private applyContext(value: unknown): void {
    if (!isRecord(value)) return
    if (value.theme === "light" || value.theme === "dark") this.state = { ...this.state, theme: value.theme }
  }
  private onMessage = (event: MessageEvent): void => {
    if (event.source !== this.hostWindow.parent || !isRecord(event.data) || event.data.jsonrpc !== "2.0") return
    const message = event.data
    if (message.method === "ping" && (typeof message.id === "number" || typeof message.id === "string")) {
      this.send({ id: message.id, result: {} })
      return
    }
    if (message.method === "ui/resource-teardown" && (typeof message.id === "number" || typeof message.id === "string")) {
      this.send({ id: message.id, result: {} })
      this.dispose()
      return
    }
    if (message.method === undefined && typeof message.id === "number") {
      const pending = this.pending.get(message.id)
      if (!pending) return
      this.pending.delete(message.id)
      this.hostWindow.clearTimeout(pending.timeout)
      if (message.error !== undefined) pending.reject(new HostRequestError(message.error))
      else pending.resolve(message.result)
      return
    }
    if (this.state.status !== "ready") return
    if (message.method === "ui/notifications/tool-result") this.emit({ kind: "result", result: message.params })
    if (message.method === "ui/notifications/host-context-changed") {
      this.applyContext(message.params)
      this.emit({ kind: "state", state: this.state })
    }
  }
}
