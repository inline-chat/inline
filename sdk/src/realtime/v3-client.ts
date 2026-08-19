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
  /** Persist replacement credentials before the authenticated session becomes visible. */
  onCredentials?: (credentials: InlineProtocolV3Credentials) => void | Promise<void>
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
  #generation = 0
  #activeSessionCalls = 0
  #rotationDueSession: InlineProtocolV3Connection | undefined
  #rotationTask: Promise<void> | undefined
  #rotationError: Error | undefined

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
    const generation = this.#generation
    this.#credentials = cloneCredentials(credentials)
    const temporary = this.#credentials.temporary
    if (temporary && temporary.expiresAt !== undefined) {
      const opened = await this.#openTemporarySession(generation, {
        authorization: temporary,
      })
      const session = opened.session
      try {
        await session.probeTemporaryAuthorization()
        if (!session.temporaryAuthorizationNeedsRotation()) {
          this.#requireCurrent(generation)
          this.#session = session
          if (opened.rotationDue) this.#handleRotationDue(session, generation)
          return
        }
      } catch (error) {
        if (!(error instanceof InlineProtocolV3Error) || error.code !== "unauthorized") {
          await session.close()
          throw error
        }
      }
      await session.close()
    }
    await this.#replaceAuthenticatedSession(generation)
  }

  async reconnect(): Promise<void> {
    const credentials = this.credentials
    if (!credentials) throw new InlineProtocolV3Error("unauthorized", "No Inline Protocol credentials are available")
    await this.connect(credentials)
  }

  async callRpc(rpc: RpcCall): Promise<RpcResult["result"]> {
    return await this.#withSessionCall((session) => session.callRpc(rpc))
  }

  async createHttpUpload(request: CreateHttpUploadRequest): Promise<CreateHttpUploadResult> {
    return await this.#withSessionCall((session) => session.createHttpUpload(request))
  }

  async finishHttpUpload(request: FinishHttpUploadRequest): Promise<FinishHttpUploadResult> {
    return await this.#withSessionCall((session) => session.finishHttpUpload(request))
  }

  async close(): Promise<void> {
    ++this.#generation
    const connections = [this.#login, this.#session].filter((value): value is InlineProtocolV3Connection => value !== undefined)
    const rotationTask = this.#rotationTask
    this.#login = undefined
    this.#session = undefined
    this.#rotationDueSession = undefined
    this.#rotationError = undefined
    await Promise.allSettled([
      ...connections.map((connection) => connection.close()),
      ...(rotationTask ? [rotationTask] : []),
    ])
  }

  async #replaceAuthenticatedSession(
    generation = this.#generation,
    expectedSession?: InlineProtocolV3Connection,
  ): Promise<void> {
    const credentials = this.#credentials
    if (!credentials) throw new InlineProtocolV3Error("unauthorized", "Permanent authorization key is unavailable")
    if (expectedSession && this.#session !== expectedSession) return
    const previousSession = this.#session
    this.#session = undefined
    await previousSession?.close()
    this.#requireCurrent(generation)
    const opened = await this.#openTemporarySession(generation, {
      temporary: true,
    })
    const session = opened.session
    try {
      await session.bindTemporary(credentials.permanent)
      this.#requireCurrent(generation)
      const nextCredentials = cloneCredentials(credentials)
      nextCredentials.temporary = session.authorization
      await this.#options.onCredentials?.(cloneCredentials(nextCredentials))
      this.#requireCurrent(generation)
      this.#credentials = nextCredentials
    } catch (error) {
      await session.close()
      throw error
    }
    this.#session = session
    this.#rotationError = undefined
    if (this.#rotationDueSession === expectedSession) this.#rotationDueSession = undefined
    if (opened.rotationDue) this.#handleRotationDue(session, generation)
    const login = this.#login
    this.#login = undefined
    await login?.close()
  }

  async #openTemporarySession(
    generation: number,
    authorization: { authorization?: InlineProtocolAuthorization; temporary?: boolean },
  ): Promise<{ session: InlineProtocolV3Connection; rotationDue: boolean }> {
    const owner: { session?: InlineProtocolV3Connection; rotationDue: boolean } = { rotationDue: false }
    const session = await InlineProtocolV3Connection.connect({
      ...this.#connectionOptions(),
      ...authorization,
      onRotationDue: () => {
        owner.rotationDue = true
        if (owner.session) this.#handleRotationDue(owner.session, generation)
      },
    })
    owner.session = session
    return { session, rotationDue: owner.rotationDue }
  }

  #handleRotationDue(session: InlineProtocolV3Connection, generation: number): void {
    if (generation !== this.#generation || this.#session !== session) return
    this.#rotationDueSession = session
    this.#maybeRotate()
  }

  #maybeRotate(): void {
    const session = this.#rotationDueSession
    if (!session || this.#session !== session || this.#activeSessionCalls > 0 || this.#rotationTask) return
    const generation = this.#generation
    const task = this.#replaceAuthenticatedSession(generation, session)
    this.#rotationTask = task
    void task
      .catch((error: unknown) => {
        if (generation !== this.#generation) return
        this.#rotationError = error instanceof Error ? error : new Error(String(error))
      })
      .finally(() => {
        if (this.#rotationTask === task) this.#rotationTask = undefined
        if (generation === this.#generation) this.#maybeRotate()
      })
  }

  async #withSessionCall<T>(operation: (session: InlineProtocolV3Connection) => Promise<T>): Promise<T> {
    if (this.#rotationTask) await this.#rotationTask
    if (this.#rotationDueSession) {
      this.#maybeRotate()
      if (this.#rotationTask) await this.#rotationTask
    }
    if (this.#rotationError) throw this.#rotationError
    const session = this.#requireSession()
    this.#activeSessionCalls += 1
    try {
      return await operation(session)
    } finally {
      this.#activeSessionCalls -= 1
      this.#maybeRotate()
    }
  }

  #requireCurrent(generation: number): void {
    if (generation !== this.#generation) {
      throw new InlineProtocolV3Error("closed", "Inline Protocol client lifecycle changed")
    }
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
