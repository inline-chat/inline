type CdpResponse = {
  id?: number
  result?: Record<string, unknown>
  error?: { message: string }
}

export type ChromeTargetInfo = {
  targetId: string
  type: string
  title: string
  url: string
}

export class ChromeDevtoolsBrowser {
  private nextId = 0
  private readonly continuations = new Map<
    number,
    {
      resolve: (response: CdpResponse) => void
      reject: (error: Error) => void
    }
  >()

  private constructor(private readonly socket: WebSocket) {
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
    const response = await fetch(`${debuggerOrigin}/json/version`)
    if (!response.ok) {
      throw new Error(
        `Could not inspect Chrome debugger: ${response.status}`,
      )
    }
    const version = (await response.json()) as {
      webSocketDebuggerUrl: string
    }
    const socket = new WebSocket(version.webSocketDebuggerUrl)
    await new Promise<void>((resolve, reject) => {
      socket.addEventListener("open", () => resolve(), {
        once: true,
      })
      socket.addEventListener(
        "error",
        () =>
          reject(
            new Error("Chrome browser debugger WebSocket failed"),
          ),
        { once: true },
      )
    })
    return new ChromeDevtoolsBrowser(socket)
  }

  async targets(): Promise<ChromeTargetInfo[]> {
    const response = await this.call("Target.getTargets")
    const result = response.result as
      | { targetInfos?: ChromeTargetInfo[] }
      | undefined
    return result?.targetInfos ?? []
  }

  async closeTarget(targetId: string) {
    await this.call("Target.closeTarget", { targetId })
  }

  close() {
    this.socket.close()
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
}
