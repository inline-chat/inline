import WebSocket from "ws"
import { pcm16le } from "./pcm.js"
import { TranscriptionError, type FinalTurn, type Model, type TurnDecoder } from "./protocol.js"
import { OPENAI_URL, OPENAI_SAMPLE_RATE, OpenAITurnDecoder, openAIConfiguration, openAIConfigurationAccepted, openAIAppendAudio, openAICommit } from "./providers/openai.js"
import { SONIOX_URL, SONIOX_SAMPLE_RATE, SonioxTurnDecoder, sonioxConfiguration, sonioxAudio, sonioxFinalize, sonioxKeepalive } from "./providers/soniox.js"

const MAX_SOCKET_BYTES = 128 * 1024
const MAX_EVENT_BYTES = 64 * 1024

export type SocketFactory = (url: string, headers: Readonly<Record<string, string>>) => WebSocket
export type ProviderOptions = {
  model: Model; apiKey: string;
  assertAuthority: () => void;
  onFinal: (turn: FinalTurn) => void;
  onFailure: (error: TranscriptionError) => void;
  connectTimeoutMs?: number;
  // Trusted dependency injection for controlled local qualification, never client-supplied.
  socketFactory?: SocketFactory;
}

export class ProviderConnection {
  readonly sampleRate: number
  private readonly socket: WebSocket
  private readonly decoder: TurnDecoder
  private closed = false
  private ready = false
  private keepalive: ReturnType<typeof setInterval> | undefined
  private failure: TranscriptionError | undefined

  private constructor(private readonly options: ProviderOptions) {
    options.assertAuthority()
    if (options.model !== "standard" && options.model !== "meeting") throw new TranscriptionError("protocol")
    if (typeof options.apiKey !== "string" || !options.apiKey || options.apiKey.length > 4096 || /[\r\n]/.test(options.apiKey)) {
      throw new TranscriptionError("protocol")
    }
    const timeoutMs = options.connectTimeoutMs ?? 5_000
    if (!Number.isFinite(timeoutMs) || timeoutMs < 1 || timeoutMs > 30_000) throw new TranscriptionError("protocol")
    this.sampleRate = options.model === "standard" ? OPENAI_SAMPLE_RATE : SONIOX_SAMPLE_RATE
    this.decoder = options.model === "standard" ? new OpenAITurnDecoder() : new SonioxTurnDecoder()
    const headers: Record<string, string> = options.model === "standard" ? { Authorization: `Bearer ${options.apiKey}` } : {}
    const factory = options.socketFactory ?? ((url, values) => new WebSocket(url, { headers: values, maxPayload: MAX_EVENT_BYTES }))
    this.socket = factory(options.model === "standard" ? OPENAI_URL : SONIOX_URL, headers)
  }

  static async connect(options: ProviderOptions): Promise<ProviderConnection> {
    let connection: ProviderConnection | undefined
    try {
      connection = new ProviderConnection(options)
      await connection.open()
      return connection
    } catch (error) {
      connection?.close()
      throw error instanceof TranscriptionError ? error : new TranscriptionError("provider")
    }
  }

  private open(): Promise<void> {
    const timeoutMs = this.options.connectTimeoutMs ?? 5_000
    return new Promise((resolve, reject) => {
      let settled = false
      const finish = (error?: TranscriptionError) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        if (error) reject(error)
        else { this.ready = true; resolve() }
      }
      const timer = setTimeout(() => {
        const error = new TranscriptionError("provider")
        finish(error)
        this.fail(error)
      }, timeoutMs)
      this.socket.on("error", () => {
        const error = new TranscriptionError("provider")
        finish(error)
        this.fail(error)
      })
      this.socket.on("close", () => {
        if (this.closed) return
        const error = new TranscriptionError("provider")
        finish(error)
        this.fail(error)
      })
      this.socket.on("message", (data, isBinary) => {
        if (this.closed) return
        try {
          this.options.assertAuthority()
          const bytes = Array.isArray(data) ? Buffer.concat(data) : data instanceof ArrayBuffer ? Buffer.from(data) : data
          if (isBinary || bytes.byteLength > MAX_EVENT_BYTES) throw new TranscriptionError("protocol")
          const event: unknown = JSON.parse(bytes.toString("utf8"))
          const finals = this.decoder.accept(event)
          if (this.options.model === "standard" && openAIConfigurationAccepted(event)) finish()
          for (const turn of finals) {
            if (this.closed) break
            this.options.assertAuthority()
            this.options.onFinal(turn)
          }
          if (this.options.model === "meeting" && typeof event === "object" && event !== null
            && "finished" in event && event.finished === true && !this.closed) {
            // No owner-requested end-input exists here: unexpected EOS retires this socket.
            this.fail(new TranscriptionError("provider"))
          }
        } catch (error) {
          const safe = error instanceof TranscriptionError ? error : new TranscriptionError("protocol")
          finish(safe)
          this.fail(safe)
        }
      })
      this.socket.once("open", () => {
        if (this.closed) return
        try {
          this.write(JSON.stringify(this.options.model === "standard"
            ? openAIConfiguration() : sonioxConfiguration(this.options.apiKey)), false)
          if (this.options.model === "meeting") {
            // Soniox has no distinct configuration-ack event. This is transport-ready, not audio proof.
            finish()
            this.keepalive = setInterval(() => {
              try { this.write(JSON.stringify(sonioxKeepalive())) }
              catch (error) { this.fail(error instanceof TranscriptionError ? error : new TranscriptionError("provider")) }
            }, 10_000)
          }
        } catch (error) {
          const safe = error instanceof TranscriptionError ? error : new TranscriptionError("provider")
          finish(safe)
          this.fail(safe)
        }
      })
    })
  }

  appendAudio(samples: Int16Array): void {
    this.perform(() => {
      this.assertWritable()
      const bytes = pcm16le(samples)
      this.write(this.options.model === "standard" ? JSON.stringify(openAIAppendAudio(bytes)) : sonioxAudio(bytes))
    })
  }

  // Call only after API admission, immediately before wire commit in this same track actor.
  commitTurn(turnId: string): void {
    this.perform(() => {
      this.assertWritable()
      this.decoder.beginTurn(turnId)
      this.write(JSON.stringify(this.options.model === "standard" ? openAICommit() : sonioxFinalize()))
    })
  }

  private perform(operation: () => void): void {
    try { operation() }
    catch (error) {
      const safe = error instanceof TranscriptionError ? error : new TranscriptionError("protocol")
      this.fail(safe)
      throw safe
    }
  }

  private assertWritable(requireReady = true): void {
    if (this.closed) throw this.failure ?? new TranscriptionError("stopped")
    this.options.assertAuthority()
    if ((requireReady && !this.ready) || this.socket.readyState !== WebSocket.OPEN) throw new TranscriptionError("provider")
    if (this.socket.bufferedAmount > MAX_SOCKET_BYTES) {
      const error = new TranscriptionError("overflow")
      this.fail(error)
      throw error
    }
  }

  private write(data: string | Uint8Array, requireReady = true): void {
    this.assertWritable(requireReady)
    if (this.socket.bufferedAmount + Buffer.byteLength(data) > MAX_SOCKET_BYTES) {
      const error = new TranscriptionError("overflow")
      this.fail(error)
      throw error
    }
    this.socket.send(data, (error) => { if (error) this.fail(new TranscriptionError("provider")) })
  }

  private fail(error: TranscriptionError): void {
    if (this.closed) return
    this.failure = error
    this.close()
    this.options.onFailure(error)
  }

  // No admission/queue flush occurs here. Its owner completes accepted turns before this deadline.
  close(): void {
    if (this.closed) return
    this.closed = true
    clearInterval(this.keepalive)
    this.decoder.close()
    this.socket.terminate()
  }
}
