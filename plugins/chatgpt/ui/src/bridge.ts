import { isAccessDenied, isId, isRecord, readWidgetState, type RecordValue, type WidgetState } from "./contracts"

type OpenAIExtensions = {
  widgetState?: unknown
  toolOutput?: unknown
  toolInput?: unknown
  toolResponseMetadata?: unknown
  displayMode?: unknown
  theme?: unknown
  setWidgetState?: (state: WidgetState) => void
}
declare global { interface Window { openai?: OpenAIExtensions } }

class HostRequestError extends Error {
  constructor(readonly rpcError: unknown) { super("Host could not complete the request") }
}

export type HostState = {
  status: "connecting" | "ready" | "failed" | "closed"
  theme?: "light" | "dark"
  displayMode?: "inline" | "fullscreen" | "pip"
  canAttachContext: boolean
}

/** One standard MCP Apps connection. No browser credentials or direct API calls. */
export class HostBridge {
  private nextId = 0
  private pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void; timeout: number }>()
  private listeners = new Set<(event: { kind: "state"; state: HostState } | { kind: "result"; result: unknown }) => void>()
  private state: HostState = { status: "connecting", canAttachContext: false }
  private ready: Promise<void> | null = null
  private latestResult: unknown = undefined
  private deniedResult: unknown = undefined
  private invocationResultProvided = false
  private queuedStandardResult = false

  constructor(private readonly hostWindow: Window = window) {
    hostWindow.addEventListener("message", this.onMessage)
    hostWindow.addEventListener("openai:set_globals", this.onGlobals)
  }

  get hostState(): HostState { return this.state }
  get widgetState(): WidgetState {
    const saved = readWidgetState(this.hostWindow.openai?.widgetState)
    return isAccessDenied(this.deniedResult) || isAccessDenied(this.globalsResult(this.hostWindow.openai))
      ? { ...saved, threads: [], activeChatId: null } : saved
  }
  get hasToolResult(): boolean { return this.latestResult !== undefined }
  get initialChatId(): string | null {
    const input = this.hostWindow.openai?.toolInput
    return isRecord(input) && isId(input.chatId) ? input.chatId : null
  }
  get hasInvocationResult(): boolean {
    const globals = this.hostWindow.openai
    return this.hasToolResult || this.invocationResultProvided || globals?.toolOutput != null || globals?.toolResponseMetadata != null
  }
  saveWidgetState(state: WidgetState): void {
    try { this.hostWindow.openai?.setWidgetState?.(state) } catch { /* A host snapshot is best effort; Inline remains canonical. */ }
  }
  subscribe(listener: (event: { kind: "state"; state: HostState } | { kind: "result"; result: unknown }) => void): () => void {
    this.listeners.add(listener)
    if (this.state.status === "ready") {
      listener({ kind: "state", state: this.state })
      if (this.hasToolResult) listener({ kind: "result", result: this.deniedResult ?? this.latestResult })
    } else if (isAccessDenied(this.deniedResult)) listener({ kind: "result", result: this.deniedResult })
    return () => { this.listeners.delete(listener) }
  }

  initialize(): Promise<void> {
    this.ready ??= this.request("ui/initialize", {
      appInfo: { name: "inline-thread", version: "0.0.1" },
      appCapabilities: { availableDisplayModes: ["inline", "fullscreen"] },
      protocolVersion: "2026-01-26",
    }, 10_000).then((value) => {
      if (this.state.status === "closed") throw new Error("Host closed the thread view")
      if (!isRecord(value) || value.protocolVersion !== "2026-01-26") throw new Error("Unsupported host protocol")
      this.state = { status: "ready", canAttachContext: isRecord(value.hostCapabilities) && isRecord(value.hostCapabilities.updateModelContext) }
      this.applyContext(this.hostWindow.openai)
      this.applyContext(value.hostContext)
      const initial = this.globalsResult(this.hostWindow.openai)
      // A standard notification is newer than the launch snapshot. A known
      // denial always takes precedence over either cached success surface.
      if (initial !== undefined && (!this.hasToolResult || isAccessDenied(initial))) this.latestResult = initial
      if (isAccessDenied(this.latestResult)) this.deniedResult = this.latestResult
      this.notify("ui/notifications/initialized", {})
      this.emit({ kind: "state", state: this.state })
      if (this.hasToolResult) this.emit({ kind: "result", result: this.deniedResult ?? this.latestResult })
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
    this.hostWindow.removeEventListener("openai:set_globals", this.onGlobals)
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
    if (value.displayMode === "inline" || value.displayMode === "fullscreen" || value.displayMode === "pip") this.state = { ...this.state, displayMode: value.displayMode }
  }
  private globalsResult(value: unknown): unknown {
    if (!isRecord(value)) return undefined
    const metadata = value.toolResponseMetadata
    if (isRecord(metadata)) {
      const envelopes = [metadata.mcp_tool_result, metadata.call_tool_result, metadata]
      const denied = envelopes.find(isAccessDenied)
      if (denied) return denied
      const canonical = envelopes.slice(0, 2).find((result) => isRecord(result)
        && (result.structuredContent !== undefined || result.isError !== undefined || Array.isArray(result.content)))
      if (canonical) return canonical
      // A canonical result still in flight must not borrow an older toolOutput.
      if ("mcp_tool_result" in metadata || "call_tool_result" in metadata || "status" in metadata) return undefined
    }
    return value.toolOutput !== undefined && value.toolOutput !== null
      ? { structuredContent: value.toolOutput, ...(isRecord(metadata) ? { _meta: metadata } : {}) } : undefined
  }
  private receiveResult(result: unknown, standard = false): void {
    if (this.state.status === "closed" || this.state.status === "failed") return
    const denied = isAccessDenied(result)
    // Launch globals may arrive late, after the host has already supplied the
    // requested standard result. During bootstrap only denial may replace it.
    if (this.state.status === "connecting") {
      if (!standard && this.queuedStandardResult && !denied) return
      if (standard) this.queuedStandardResult = true
    }
    if (denied) this.deniedResult = result
    this.latestResult = result
    // Revocation must clear mounted content even when initialization is still
    // pending or will fail. Only successful snapshots wait for readiness.
    if (this.state.status === "ready" || denied) this.emit({ kind: "result", result })
  }
  private onGlobals = (event: Event): void => {
    const detail = (event as CustomEvent<unknown>).detail
    if (!isRecord(detail) || !isRecord(detail.globals)) return
    this.applyContext(detail.globals)
    if ("toolOutput" in detail.globals || "toolResponseMetadata" in detail.globals) {
      if (detail.globals.toolOutput != null || detail.globals.toolResponseMetadata != null) this.invocationResultProvided = true
      // Partial updates must not combine a new output with a previous call's
      // canonical metadata. Each result-bearing update owns its own envelope.
      const result = this.globalsResult(detail.globals)
      if (result !== undefined) this.receiveResult(result)
    }
    if (this.state.status === "ready") this.emit({ kind: "state", state: this.state })
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
    if (message.method === "ui/notifications/tool-result") { this.receiveResult(message.params, true); return }
    if (this.state.status !== "ready") return
    if (message.method === "ui/notifications/host-context-changed") {
      this.applyContext(message.params)
      this.emit({ kind: "state", state: this.state })
    }
  }
}
