import {
  makeCachedPureAesBackend,
  type InlineProtocolClock,
  type InlineProtocolGunzip,
  type InlineProtocolRuntime,
  type InlineProtocolSocketFactory,
  type InlineProtocolTimers,
} from "@inline-chat/protocol/secure/connection"

/** The browser `WebSocket` constructor shape; tests pass an in-process fake. */
export type BrowserWebSocketConstructor = new (url: string) => WebSocket

const isScriptCloseCode = (code: number) => code === 1000 || (code >= 3000 && code <= 4999)

/**
 * Adapts the browser `WebSocket` (window or worker) to the connection's socket
 * interface. Frames arrive as `ArrayBuffer`; a text frame is a protocol error.
 */
export const browserWebSocketFactory = (
  WebSocketImpl: BrowserWebSocketConstructor = globalThis.WebSocket,
): InlineProtocolSocketFactory => (url, handlers) => {
  const socket = new WebSocketImpl(url)
  socket.binaryType = "arraybuffer"
  socket.onopen = () => handlers.onOpen()
  socket.onmessage = (event: MessageEvent<unknown>) => {
    const data = event.data
    if (data instanceof ArrayBuffer) {
      handlers.onMessage(new Uint8Array(data))
    } else if (ArrayBuffer.isView(data)) {
      handlers.onMessage(new Uint8Array(data.buffer, data.byteOffset, data.byteLength).slice())
    } else {
      handlers.onError(new TypeError("Inline Protocol received a non-binary frame"))
    }
  }
  socket.onclose = (event: CloseEvent) => handlers.onClose(event.code, event.reason)
  socket.onerror = () => handlers.onError(new Error("WebSocket error"))
  return {
    get readyState() {
      return socket.readyState
    },
    get bufferedAmount() {
      return socket.bufferedAmount
    },
    send: (data) => {
      socket.send(data.buffer instanceof ArrayBuffer
        ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
        : Uint8Array.from(data))
    },
    close: (code, reason) => {
      socket.onopen = null
      socket.onmessage = null
      socket.onerror = null
      // Script may only send 1000 or 3000-4999; a protocol-failure code (1011) would throw.
      if (code === undefined) socket.close()
      else socket.close(isScriptCloseCode(code) ? code : 1000, reason)
    },
  }
}

const MAXIMUM_RANDOM_CHUNK = 65_536

/** `crypto.getRandomValues`, chunked to its per-call limit. */
export const browserRandomBytes = (length: number): Uint8Array => {
  const bytes = new Uint8Array(length)
  for (let offset = 0; offset < length; offset += MAXIMUM_RANDOM_CHUNK) {
    crypto.getRandomValues(bytes.subarray(offset, Math.min(length, offset + MAXIMUM_RANDOM_CHUNK)))
  }
  return bytes
}

/**
 * Inflates through `DecompressionStream("gzip")` and stops reading as soon as
 * the output passes the limit, so a small bomb cannot allocate its full size.
 */
export const browserGunzip: InlineProtocolGunzip = async (packed, maximumOutputBytes) => {
  const input = new Uint8Array(packed)
  const source = new ReadableStream<Uint8Array<ArrayBuffer>>({
    start(controller) {
      controller.enqueue(input)
      controller.close()
    },
  })
  const reader = source.pipeThrough(new DecompressionStream("gzip")).getReader()
  const chunks: Uint8Array[] = []
  let total = 0
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    total += value.byteLength
    if (total > maximumOutputBytes) {
      await reader.cancel().catch(() => undefined)
      throw new RangeError(`gzip output exceeds ${maximumOutputBytes} bytes`)
    }
    chunks.push(value)
  }
  const output = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    output.set(chunk, offset)
    offset += chunk.byteLength
  }
  return output
}

export type BrowserInlineProtocolRuntimeOptions = {
  WebSocket?: BrowserWebSocketConstructor
  timers?: InlineProtocolTimers
  clock?: InlineProtocolClock
}

/**
 * The V3 runtime for a browser window or worker. AES runs on the portable
 * backend with cached key schedules: WebCrypto has no ECB or IGE, and its
 * asynchronous API cannot back the synchronous record and carrier code.
 */
export const createBrowserInlineProtocolRuntime = (
  options: BrowserInlineProtocolRuntimeOptions = {},
): InlineProtocolRuntime => ({
  webSocket: browserWebSocketFactory(options.WebSocket),
  randomBytes: browserRandomBytes,
  gunzip: browserGunzip,
  aes: browserAesBackend(),
  ...(options.timers ? { timers: options.timers } : {}),
  ...(options.clock ? { clock: options.clock } : {}),
})

let sharedAes: ReturnType<typeof makeCachedPureAesBackend> | undefined
const browserAesBackend = () => (sharedAes ??= makeCachedPureAesBackend())
