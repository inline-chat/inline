import type {
  AuthBeginRequest,
  AuthBeginResult,
  AuthCompleteRequest,
  AuthCompleteResult,
  CreateHttpUploadRequest,
  CreateHttpUploadResult,
  FinishHttpUploadRequest,
  FinishHttpUploadResult,
  RpcCall,
  RpcResult,
} from "@inline-chat/protocol/core"
import {
  InlineProtocolV3Connection,
  InlineProtocolV3Error,
  type InlineProtocolAuthorization,
  type InlineProtocolPublicKey,
  type InlineProtocolV3ConnectionOptions,
} from "./v3-connection.js"

export type InlineProtocolV3Credentials = {
  permanent: InlineProtocolAuthorization
  temporary?: InlineProtocolAuthorization
}

export type InlineRealtimeV3ClientOptions = {
  url: string
  rsaPublicKeys: readonly InlineProtocolPublicKey[]
  connectTimeoutMs?: number
  requestTimeoutMs?: number
  onUpdate?: InlineProtocolV3ConnectionOptions["onUpdate"]
}

const cloneAuthorization = (value: InlineProtocolAuthorization): InlineProtocolAuthorization => ({
  ...value,
  key: value.key.slice(),
  keyId: value.keyId.slice(),
})

const cloneCredentials = (value: InlineProtocolV3Credentials): InlineProtocolV3Credentials => ({
  permanent: cloneAuthorization(value.permanent),
  ...(value.temporary ? { temporary: cloneAuthorization(value.temporary) } : {}),
})

export class InlineRealtimeV3Client {
  readonly #options: InlineRealtimeV3ClientOptions
  #login: InlineProtocolV3Connection | undefined
  #session: InlineProtocolV3Connection | undefined
  #credentials: InlineProtocolV3Credentials | undefined

  constructor(options: InlineRealtimeV3ClientOptions) {
    this.#options = options
  }

  get credentials(): InlineProtocolV3Credentials | undefined {
    if (!this.#credentials) return undefined
    const credentials = cloneCredentials(this.#credentials)
    if (this.#session) credentials.temporary = this.#session.authorization
    if (this.#login) credentials.permanent = this.#login.authorization
    return credentials
  }

  get authenticated(): boolean { return this.#session !== undefined }

  async beginLogin(request: AuthBeginRequest): Promise<AuthBeginResult> {
    await this.close()
    this.#login = await InlineProtocolV3Connection.connect(this.#connectionOptions())
    this.#credentials = { permanent: this.#login.authorization }
    return await this.#login.authBegin(request)
  }

  async completeLogin(request: AuthCompleteRequest): Promise<AuthCompleteResult> {
    const login = this.#login
    if (!login || !this.#credentials) throw new InlineProtocolV3Error("unauthorized", "Native login has not started")
    const result = await login.authComplete(request)
    this.#credentials.permanent = login.authorization
    if (result.state.oneofKind === "authorized") await this.#replaceAuthenticatedSession()
    return result
  }

  async connect(credentials: InlineProtocolV3Credentials): Promise<void> {
    await this.close()
    this.#credentials = cloneCredentials(credentials)
    const temporary = this.#credentials.temporary
    const now = Math.floor(Date.now() / 1_000)
    if (temporary && temporary.expiresAt !== undefined && temporary.expiresAt > now + 60) {
      this.#session = await InlineProtocolV3Connection.connect({
        ...this.#connectionOptions(),
        authorization: temporary,
      })
      return
    }
    await this.#replaceAuthenticatedSession()
  }

  async reconnect(): Promise<void> {
    const credentials = this.credentials
    if (!credentials) throw new InlineProtocolV3Error("unauthorized", "No Inline Protocol credentials are available")
    await this.connect(credentials)
  }

  async callRpc(rpc: RpcCall): Promise<RpcResult["result"]> {
    return await this.#requireSession().callRpc(rpc)
  }

  async createHttpUpload(request: CreateHttpUploadRequest): Promise<CreateHttpUploadResult> {
    return await this.#requireSession().createHttpUpload(request)
  }

  async finishHttpUpload(request: FinishHttpUploadRequest): Promise<FinishHttpUploadResult> {
    return await this.#requireSession().finishHttpUpload(request)
  }

  async close(): Promise<void> {
    const connections = [this.#login, this.#session].filter((value): value is InlineProtocolV3Connection => value !== undefined)
    this.#login = undefined
    this.#session = undefined
    await Promise.allSettled(connections.map((connection) => connection.close()))
  }

  async #replaceAuthenticatedSession(): Promise<void> {
    const credentials = this.#credentials
    if (!credentials) throw new InlineProtocolV3Error("unauthorized", "Permanent authorization key is unavailable")
    await this.#session?.close()
    const session = await InlineProtocolV3Connection.connect({
      ...this.#connectionOptions(),
      temporary: true,
    })
    try {
      await session.bindTemporary(credentials.permanent)
    } catch (error) {
      await session.close()
      throw error
    }
    this.#session = session
    credentials.temporary = session.authorization
  }

  #requireSession(): InlineProtocolV3Connection {
    if (!this.#session) throw new InlineProtocolV3Error("unauthorized", "Inline Protocol authenticated session is not connected")
    return this.#session
  }

  #connectionOptions(): InlineProtocolV3ConnectionOptions {
    return {
      url: this.#options.url,
      rsaPublicKeys: this.#options.rsaPublicKeys,
      connectTimeoutMs: this.#options.connectTimeoutMs,
      requestTimeoutMs: this.#options.requestTimeoutMs,
      onUpdate: this.#options.onUpdate,
    }
  }
}
