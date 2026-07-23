type CdpResponse = {
  id?: number
  method?: string
  result?: Record<string, unknown>
  error?: { message: string }
}

export class ChromeDevtoolsPage {
  private nextId = 0
  private readonly continuations = new Map<
    number,
    {
      resolve: (response: CdpResponse) => void
      reject: (error: Error) => void
    }
  >()

  private constructor(
    private readonly debuggerOrigin: string,
    private readonly targetId: string,
    private readonly socket: WebSocket,
  ) {
    socket.addEventListener("message", (event) => {
      const response = JSON.parse(String(event.data)) as CdpResponse
      if (response.id == null) return
      const continuation = this.continuations.get(response.id)
      if (!continuation) return
      this.continuations.delete(response.id)
      if (response.error) {
        continuation.reject(new Error(response.error.message))
      } else {
        continuation.resolve(response)
      }
    })
  }

  static async open(debuggerOrigin: string) {
    const response = await fetch(
      `${debuggerOrigin}/json/new?${encodeURIComponent("about:blank")}`,
      { method: "PUT" },
    )
    if (!response.ok) {
      throw new Error(`Could not create Chrome target: ${response.status}`)
    }
    const target = (await response.json()) as {
      id: string
      webSocketDebuggerUrl: string
    }
    const socket = new WebSocket(target.webSocketDebuggerUrl)
    await new Promise<void>((resolve, reject) => {
      socket.addEventListener("open", () => resolve(), { once: true })
      socket.addEventListener(
        "error",
        () => reject(new Error("Chrome debugger WebSocket failed")),
        { once: true },
      )
    })
    const page = new ChromeDevtoolsPage(
      debuggerOrigin,
      target.id,
      socket,
    )
    await page.call("Runtime.enable")
    await page.call("Page.enable")
    return page
  }

  async navigate(url: string) {
    const loaded = this.waitForEvent("Page.loadEventFired")
    await this.call("Page.navigate", { url })
    await loaded
  }

  async reload() {
    const loaded = this.waitForEvent("Page.loadEventFired")
    try {
      await this.call("Page.reload", { ignoreCache: true })
    } catch (error) {
      if (
        !(error instanceof Error) ||
        !error.message.includes("Inspected target navigated")
      ) {
        throw error
      }
    }
    await loaded
  }

  async evaluate<T>(expression: string): Promise<T> {
    const evaluated = await this.call("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
    })
    const runtimeResult = evaluated.result as
      | { result?: { value?: T }; exceptionDetails?: unknown }
      | undefined
    if (runtimeResult?.exceptionDetails) {
      throw new Error(
        `Browser evaluation threw: ${JSON.stringify(runtimeResult.exceptionDetails)}`,
      )
    }
    return runtimeResult?.result?.value as T
  }

  async setNetworkOffline(offline: boolean) {
    await this.call("Network.enable")
    await this.call("Network.emulateNetworkConditions", {
      offline,
      latency: 0,
      downloadThroughput: -1,
      uploadThroughput: -1,
      connectionType: offline ? "none" : "wifi",
    })
  }

  async close() {
    this.socket.close()
    await fetch(
      `${this.debuggerOrigin}/json/close/${this.targetId}`,
    ).catch(() => undefined)
  }

  private call(
    method: string,
    params: Record<string, unknown> = {},
  ) {
    const id = ++this.nextId
    return new Promise<CdpResponse>((resolve, reject) => {
      this.continuations.set(id, { resolve, reject })
      this.socket.send(JSON.stringify({ id, method, params }))
    })
  }

  private waitForEvent(method: string) {
    return new Promise<void>((resolve) => {
      const listener = (event: MessageEvent) => {
        const message = JSON.parse(String(event.data)) as CdpResponse
        if (message.method !== method) return
        this.socket.removeEventListener("message", listener)
        resolve()
      }
      this.socket.addEventListener("message", listener)
    })
  }
}
