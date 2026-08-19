import {
  BindingConstructor,
  decodeBindTempAuthKey,
  verifyTemporaryKeyBindingProof,
} from "./binding.js"
import {
  MAX_PACKET_BYTES,
  bytesToHex,
  equalBytes,
  int64LE,
  readInt64LE,
  uint32LE,
} from "./bytes.js"
import {
  InlineHandshakeServer,
  type EstablishedAuthorizationKey,
  type HandshakeRsaServerKey,
} from "./handshakeState.js"
import {
  decodeUnencryptedRecord,
  encodeUnencryptedRecord,
} from "./handshakeSchema.js"
import {
  INLINE_REALTIME_LAYER,
  INLINE_INVOKE_CONSTRUCTOR,
  decodeInlineApplicationObject,
  encodeInlineResult,
  encodeInlineUpdate,
} from "./application.js"
import {
  InvalidEncryptedRecord,
  RecoverableEncryptedRecordError,
  decryptRecordWithMetadata,
  encryptRecord,
  type EncryptedRecordFields,
} from "./record.js"
import {
  AcknowledgementQueue,
  MessageIdGenerator,
  PendingMessageCache,
  ReceiveMessageWindow,
  ReceiveSequenceValidator,
  SequenceNumberGenerator,
  validateInboundMessageId,
} from "./session.js"
import {
  ServiceConstructor,
  decodeGzipPacked,
  decodeHttpWait,
  decodeInvokeAfter,
  decodeDestroySession,
  decodeGetFutureSalts,
  decodeMessageContainer,
  decodeMsgCopy,
  decodeMsgResendReq,
  decodeMsgsAck,
  decodeMsgsAllInfo,
  decodeMsgsStateReq,
  decodeRpcDropAnswer,
  encodeBadMsgNotification,
  encodeBadServerSalt,
  encodeDestroyAuthKeyResult,
  encodeDestroySessionResult,
  encodeFutureSalts,
  encodeMsgsAck,
  encodeMsgsStateInfo,
  encodePong,
  encodeNewSessionCreated,
  encodeRpcDropAnswerResult,
  encodeRpcError,
  encodeRpcResult,
  serviceConstructor,
} from "./service.js"

const BOOL_TRUE = 0x997275b5
const MAX_SESSION_OUTPUTS = 2048
const MAX_COMPLETED_INCOMING_MESSAGES = 8192
const MAX_DEFERRED_INVOKE_AFTER = 1024
const MAX_IN_FLIGHT_APPLICATIONS = 64
const MAX_INVOKE_AFTER_NESTING = 16
const DEFAULT_APPLICATION_TIMEOUT_MS = 30_000

/** The account authorization behind an otherwise valid encrypted session is no longer active. */
export class InlineProtocolAuthorizationInvalidated extends Error {
  constructor() {
    super("Authorization key is no longer active")
    this.name = "InlineProtocolAuthorizationInvalidated"
  }
}

/** Application execution may have committed, but its retained update output exceeded capacity. */
export class InlineProtocolApplicationOutputOverloaded extends Error {
  constructor() {
    super("Inline Protocol application update capacity exceeded")
    this.name = "InlineProtocolApplicationOutputOverloaded"
  }
}
const NON_CONTENT_CONSTRUCTORS = new Set<number>([
  ServiceConstructor.msgContainer,
  ServiceConstructor.msgsAck,
  ServiceConstructor.msgResendReq,
  ServiceConstructor.msgsStateReq,
  ServiceConstructor.msgsStateInfo,
  ServiceConstructor.msgsAllInfo,
  ServiceConstructor.msgDetailedInfo,
  ServiceConstructor.msgNewDetailedInfo,
  ServiceConstructor.ping,
  ServiceConstructor.pingDelayDisconnect,
  ServiceConstructor.pong,
  ServiceConstructor.httpWait,
])

export type LoadedServerAuthorizationKey = {
  key: Uint8Array
  keyId: Uint8Array
  temporary: boolean
  expiresAt?: number
  currentServerSalt: bigint
  previousServerSalt?: bigint
  authorized?: { userId: number; accountSessionId: number }
  binding?: {
    permanentAuthKeyId: Uint8Array
    temporarySessionId: bigint
    nonce: bigint
    expiresAt: number
    userId: number
    accountSessionId: number
  }
}

export interface ServerAuthorizationKeyRepository {
  create(key: EstablishedAuthorizationKey): Promise<"created" | "collision">
  load(authKeyId: Uint8Array): Promise<LoadedServerAuthorizationKey | undefined>
  bindTemporary(input: {
    temporaryAuthKeyId: Uint8Array
    permanentAuthKeyId: Uint8Array
    temporarySessionId: bigint
    nonce: bigint
    expiresAt: number
    userId: number
    accountSessionId: number
  }): Promise<"created" | "idempotent" | "conflict">
  rotateServerSalt(authKeyId: Uint8Array, newServerSalt: bigint): Promise<boolean>
  revoke(authKeyId: Uint8Array): Promise<boolean>
}

export type ServerReplayClaim =
  | { kind: "claimed" }
  | { kind: "in_flight" }
  | { kind: "completed"; resultBody: Uint8Array }
  | { kind: "digest_mismatch" }

export interface ServerReplayRepository {
  claim(input: {
    authKeyId: Uint8Array
    sessionId: bigint
    messageId: bigint
    authenticatedBody: Uint8Array
  }): Promise<ServerReplayClaim>
  complete(input: {
    authKeyId: Uint8Array
    sessionId: bigint
    messageId: bigint
    resultBody: Uint8Array
  }): Promise<{ kind: "completed" } | { kind: "superseded"; resultBody: Uint8Array }>
  dropAnswer(input: {
    authKeyId: Uint8Array
    sessionId: bigint
    messageId: bigint
    runningResultBody: Uint8Array
  }): Promise<"running" | "unknown">
  forgetAnswer(input: {
    authKeyId: Uint8Array
    sessionId: bigint
    messageId: bigint
    forgottenResultBody: Uint8Array
  }): Promise<void>
}

export type ServerApplicationAuthorization = {
  authKeyId: Uint8Array
  permanentAuthKeyId?: Uint8Array
  permanent: boolean
  temporaryBound: boolean
  userId?: number
  accountSessionId?: number
}

export interface ServerApplicationDispatcher {
  dispatch(input: {
    payload: Uint8Array
    authorization: ServerApplicationAuthorization
    messageId: bigint
    sessionId: bigint
    signal: AbortSignal
    /**
     * Must be called immediately before entering application-owned execution,
     * after any admission or ordering wait that can reject without execution.
     */
    markExecutionStarted: () => void
    sendUpdate: (payload: Uint8Array) => void
  }): Promise<
    | { kind: "result"; payload: Uint8Array; terminateAuthorization?: boolean }
    | { kind: "error"; code: number; message: string; terminateAuthorization?: boolean }
  >
}

type LogicalMessage = {
  messageId: bigint
  sequenceNumber: number
  body: Uint8Array
  authenticatedBody?: Uint8Array
}

type PreparedLogicalMessage = {
  message: LogicalMessage
  constructor: number
  contentRelated: boolean
  duplicate: boolean
  dependencies: bigint[]
}

export interface InlineProtocolServerSessionOptions {
  rsaKeys: readonly HandshakeRsaServerKey[]
  authorizationKeys: ServerAuthorizationKeyRepository
  replay: ServerReplayRepository
  application: ServerApplicationDispatcher
  randomBytes: (length: number) => Uint8Array
  nowMilliseconds: () => number
  gunzip: (packed: Uint8Array, maximumOutputBytes: number) => Uint8Array
  carrierProfile?: "websocket" | "http"
  dc?: number
  applicationTimeoutMs?: number
  /** Returns a permit release function, or undefined to reject before execution. */
  tryAcquireApplication?: (authorization: ServerApplicationAuthorization) => (() => void) | undefined
  /** Reserves process-owned update bytes until the application is finalized. */
  tryReserveApplicationUpdateBytes?: (bytes: number) => (() => void) | undefined
}

export interface InlineProtocolServerReceiveOptions {
  onQuickAck?: (quickAckId: number) => void
}

export type InlineProtocolServerReceiveResult = {
  responses: Uint8Array[]
  applicationTasks: InlineProtocolServerApplicationTask[]
}

export interface InlineProtocolServerApplicationCompletion {
  readonly messageId: bigint
  /**
   * Present only when the response deadline won before application execution settled.
   * The host must retain and finalize this completion so replay, ordering, and capacity
   * reflect the actual execution outcome rather than the deadline response.
   */
  readonly settlement?: Promise<InlineProtocolServerApplicationCompletion>
  finalize(): Promise<InlineProtocolServerReceiveResult>
}

export interface InlineProtocolServerApplicationTask {
  readonly messageId: bigint
  dispatch(): Promise<InlineProtocolServerApplicationCompletion>
}

type LogicalHandlingResult = {
  result: InlineProtocolServerReceiveResult
  completed: boolean
}

export class InlineProtocolServerSession {
  readonly #messageIds = new MessageIdGenerator()
  readonly #sequenceNumbers = new SequenceNumberGenerator()
  readonly #receivedIds = new ReceiveMessageWindow()
  readonly #receivedSequences = new ReceiveSequenceValidator()
  readonly #acknowledgements = new AcknowledgementQueue()
  readonly #pending = new PendingMessageCache()
  readonly #completedIncoming = new Map<bigint, true>()
  readonly #deferredInvokeAfter = new Map<bigint, PreparedLogicalMessage>()
  readonly #inFlightApplications = new Set<bigint>()
  readonly #droppedApplicationAnswers = new Set<bigint>()
  readonly #handshake: InlineHandshakeServer
  #authorization: LoadedServerAuthorizationKey | undefined
  #sessionId: bigint | undefined
  #destroyed = false

  constructor(private readonly options: InlineProtocolServerSessionOptions) {
    const applicationTimeoutMs = options.applicationTimeoutMs ?? DEFAULT_APPLICATION_TIMEOUT_MS
    if (!Number.isSafeInteger(applicationTimeoutMs) || applicationTimeoutMs < 1) {
      throw new RangeError("Invalid Inline Protocol application timeout")
    }
    this.#handshake = new InlineHandshakeServer({
      rsaKeys: options.rsaKeys,
      randomBytes: options.randomBytes,
      nowSeconds: () => Math.floor(options.nowMilliseconds() / 1000),
      authorizationKeys: {
        create: (key) => options.authorizationKeys.create(key),
      },
      dc: options.dc,
    })
  }

  get destroyed(): boolean { return this.#destroyed }
  get hasEstablishedAuthorization(): boolean { return this.#authorization !== undefined }

  async receive(
    payload: Uint8Array,
    receiveOptions: InlineProtocolServerReceiveOptions = {},
  ): Promise<Uint8Array[]> {
    const accepted = await this.receiveConcurrent(payload, receiveOptions)
    const responses = [...accepted.responses]
    const applicationTasks = [...accepted.applicationTasks]
    while (applicationTasks.length > 0) {
      const task = applicationTasks.shift()!
      const completion = await task.dispatch()
      const finalized = await completion.finalize()
      responses.push(...finalized.responses)
      applicationTasks.push(...finalized.applicationTasks)
      if (responses.length > MAX_SESSION_OUTPUTS) throw new RangeError("Too many Inline Protocol outputs")
    }
    return responses
  }

  async receiveConcurrent(
    payload: Uint8Array,
    receiveOptions: InlineProtocolServerReceiveOptions = {},
  ): Promise<InlineProtocolServerReceiveResult> {
    if (this.#destroyed) throw new InvalidEncryptedRecord()
    if (payload.length < 8 || payload.length > MAX_PACKET_BYTES) throw new InvalidEncryptedRecord()
    if (payload.slice(0, 8).every((byte) => byte === 0)) {
      return { responses: [await this.#receiveHandshake(payload)], applicationTasks: [] }
    }
    return this.#receiveEncrypted(payload, receiveOptions)
  }

  sendApplicationUpdate(payload: Uint8Array): Uint8Array {
    if (this.#destroyed) throw new InvalidEncryptedRecord()
    return this.#encryptOutgoing(encodeInlineUpdate(payload), true, 3)
  }

  async #receiveHandshake(payload: Uint8Array): Promise<Uint8Array> {
    if (this.#authorization !== undefined) throw new InvalidEncryptedRecord()
    const request = decodeUnencryptedRecord(payload)
    const validation = validateInboundMessageId(
      request.messageId,
      "client",
      Math.floor(this.options.nowMilliseconds() / 1000),
    )
    if (validation.kind === "bad") throw new InvalidEncryptedRecord()
    const result = await this.#handshake.receive(request.body)
    if (result.established) {
      this.#authorization = {
        ...result.established,
        currentServerSalt: result.established.serverSalt,
      }
    }
    return encodeUnencryptedRecord(this.#nextServerMessageId(1), result.response)
  }

  async #receiveEncrypted(
    payload: Uint8Array,
    receiveOptions: InlineProtocolServerReceiveOptions,
  ): Promise<InlineProtocolServerReceiveResult> {
    const authKeyId = payload.slice(0, 8)
    if (!this.#authorization || bytesToHex(this.#authorization.keyId) !== bytesToHex(authKeyId)) {
      if (this.#sessionId !== undefined) throw new InvalidEncryptedRecord()
      const loaded = await this.options.authorizationKeys.load(authKeyId)
      // A server restart intentionally forgets process-local temporary keys. Surface the same
      // authorization-invalidated classification used for revoked keys so a client can prove its
      // permanent authority and bind a replacement instead of retrying the stale key forever.
      if (!loaded) throw new InlineProtocolAuthorizationInvalidated()
      this.#authorization = loaded
      this.#sessionId = undefined
    }
    const authorization = this.#authorization
    let fields: EncryptedRecordFields
    let quickAckId: number
    try {
      const decrypted = decryptRecordWithMetadata(payload, authorization.key, {
        direction: "client-to-server",
        sessionId: this.#sessionId,
        validServerSalts: new Set([
          authorization.currentServerSalt,
          ...(authorization.previousServerSalt === undefined ? [] : [authorization.previousServerSalt]),
        ]),
        nowSeconds: Math.floor(this.options.nowMilliseconds() / 1000),
      })
      fields = decrypted.fields
      quickAckId = decrypted.quickAckId
    } catch (error) {
      if (error instanceof RecoverableEncryptedRecordError &&
          (this.#sessionId === undefined || this.#sessionId === error.fields.sessionId)) {
        this.#sessionId = error.fields.sessionId
        const recovery = error.errorCode === 48
          ? encodeBadServerSalt(
            error.fields.messageId,
            error.fields.sequenceNumber,
            48,
            authorization.currentServerSalt,
          )
          : encodeBadMsgNotification(
            error.fields.messageId,
            error.fields.sequenceNumber,
            error.errorCode,
          )
        return {
          responses: [this.#encryptOutgoing(recovery, false, 1)],
          applicationTasks: [],
        }
      }
      throw error
    }
    const newSession = this.#sessionId === undefined
    this.#sessionId ??= fields.sessionId
    if (fields.sessionId !== this.#sessionId) throw new InvalidEncryptedRecord()

    const receivedIdsCheckpoint = this.#receivedIds.checkpoint()
    const receivedSequencesCheckpoint = this.#receivedSequences.checkpoint()
    let messages: LogicalMessage[]
    if (serviceConstructor(fields.body) === ServiceConstructor.msgContainer) {
      const outerError = this.#validateLogical(fields, false, true)
      if (outerError !== undefined) {
        this.#receivedIds.restore(receivedIdsCheckpoint)
        this.#receivedSequences.restore(receivedSequencesCheckpoint)
        return {
          responses: [this.#encryptOutgoing(
            encodeBadMsgNotification(fields.messageId, fields.sequenceNumber, outerError), false, 1,
          )],
          applicationTasks: [],
        }
      }
      messages = this.#expandContainer(fields)
    } else {
      messages = [fields]
    }
    const prepared: PreparedLogicalMessage[] = []
    for (const message of messages) {
      const originalBody = message.body
      const unwrapped = this.#unwrapInvokeAfter(originalBody)
      const constructor = serviceConstructor(unwrapped.body)
      const contentRelated = unwrapped.wrapped || this.#isContentRelated(constructor)
      const allowDuplicate = unwrapped.wrapped ||
        constructor === BindingConstructor.bindTempAuthKey ||
        constructor === ServiceConstructor.gzipPacked ||
        constructor === ServiceConstructor.msgCopy ||
        constructor === INLINE_INVOKE_CONSTRUCTOR
      const duplicate = this.#receivedIds.has(message.messageId)
      const validation = this.#validateLogical(message, contentRelated, allowDuplicate)
      if (validation !== undefined) {
        this.#receivedIds.restore(receivedIdsCheckpoint)
        this.#receivedSequences.restore(receivedSequencesCheckpoint)
        return {
          responses: [this.#encryptOutgoing(
            encodeBadMsgNotification(message.messageId, message.sequenceNumber, validation), false, 1,
          )],
          applicationTasks: [],
        }
      }
      prepared.push({
        message: !unwrapped.wrapped ? message : {
          ...message,
          body: unwrapped.body,
          authenticatedBody: message.authenticatedBody ?? originalBody,
        },
        constructor,
        contentRelated,
        duplicate,
        dependencies: unwrapped.dependencies,
      })
    }

    receiveOptions.onQuickAck?.(quickAckId)

    const prefixResponses: Uint8Array[] = []
    if (newSession) {
      const firstContent = prepared.find((item) => item.contentRelated)?.message
      if (firstContent) {
        prefixResponses.push(this.#encryptOutgoing(encodeNewSessionCreated(
          firstContent.messageId,
          readInt64LE(this.options.randomBytes(8), 0),
          authorization.currentServerSalt,
        ), true, 1))
      }
    }
    const responses: Uint8Array[] = []
    const applicationTasks: InlineProtocolServerApplicationTask[] = []
    for (const item of prepared) {
      if (item.contentRelated) this.#acknowledgements.add(item.message.messageId)
      if (this.#dependenciesComplete(item.dependencies)) {
        const handled = await this.#completePreparedConcurrent(item)
        responses.push(...handled.responses)
        applicationTasks.push(...handled.applicationTasks)
        const deferred = await this.#drainDeferredConcurrent()
        responses.push(...deferred.responses)
        applicationTasks.push(...deferred.applicationTasks)
      } else {
        this.#defer(item)
      }
      if (prefixResponses.length + responses.length > MAX_SESSION_OUTPUTS) {
        throw new RangeError("Too many Inline Protocol outputs")
      }
    }
    const acknowledgements = this.#acknowledgements.drain()
    const acknowledgementResponses = acknowledgements.length > 0
      ? [this.#encryptOutgoing(encodeMsgsAck(acknowledgements), false, 1)]
      : []
    return {
      responses: [...prefixResponses, ...acknowledgementResponses, ...responses],
      applicationTasks,
    }
  }

  #expandContainer(outer: LogicalMessage): LogicalMessage[] {
    const children = decodeMessageContainer(outer.body)
    if (children.some((child) => child.messageId >= outer.messageId)) throw new RangeError("Container ID must exceed child IDs")
    return children
  }

  #unwrapInvokeAfter(body: Uint8Array): { body: Uint8Array; dependencies: bigint[]; wrapped: boolean } {
    const dependencies: bigint[] = []
    let query = body
    for (let depth = 0; depth < MAX_INVOKE_AFTER_NESTING; depth += 1) {
      const constructor = serviceConstructor(query)
      if (constructor !== ServiceConstructor.invokeAfterMsg &&
          constructor !== ServiceConstructor.invokeAfterMsgs) {
        return { body: query, dependencies, wrapped: dependencies.length > 0 || query !== body }
      }
      const wrapper = decodeInvokeAfter(query)
      dependencies.push(...wrapper.messageIds)
      if (dependencies.length > 8192) throw new RangeError("Too many invoke-after dependencies")
      query = wrapper.query
    }
    throw new RangeError("Invoke-after nesting exceeds the limit")
  }

  #dependenciesComplete(dependencies: readonly bigint[]): boolean {
    return dependencies.every((messageId) => this.#completedIncoming.has(messageId))
  }

  #defer(item: PreparedLogicalMessage): void {
    const existing = this.#deferredInvokeAfter.get(item.message.messageId)
    if (existing) {
      if (!equalBytes(
        existing.message.authenticatedBody ?? existing.message.body,
        item.message.authenticatedBody ?? item.message.body,
      )) throw new RangeError("Conflicting deferred invoke-after replay")
      return
    }
    if (this.#deferredInvokeAfter.size >= MAX_DEFERRED_INVOKE_AFTER) {
      throw new RangeError("Too many deferred invoke-after queries")
    }
    this.#deferredInvokeAfter.set(item.message.messageId, item)
  }

  async #completePreparedConcurrent(
    item: PreparedLogicalMessage,
  ): Promise<InlineProtocolServerReceiveResult> {
    const handled = await this.#handleLogicalConcurrent(item.message, item)
    if (handled.completed) this.#markCompleted(item.message.messageId)
    return handled.result
  }

  #markCompleted(messageId: bigint): void {
    this.#completedIncoming.delete(messageId)
    this.#completedIncoming.set(messageId, true)
    if (this.#completedIncoming.size > MAX_COMPLETED_INCOMING_MESSAGES) {
      const oldest = this.#completedIncoming.keys().next().value
      if (oldest !== undefined) this.#completedIncoming.delete(oldest)
    }
  }

  async #drainDeferredConcurrent(): Promise<InlineProtocolServerReceiveResult> {
    const responses: Uint8Array[] = []
    const applicationTasks: InlineProtocolServerApplicationTask[] = []
    let madeProgress = true
    while (madeProgress) {
      madeProgress = false
      for (const [messageId, item] of this.#deferredInvokeAfter) {
        if (!this.#dependenciesComplete(item.dependencies)) continue
        this.#deferredInvokeAfter.delete(messageId)
        const handled = await this.#completePreparedConcurrent(item)
        responses.push(...handled.responses)
        applicationTasks.push(...handled.applicationTasks)
        if (responses.length > MAX_SESSION_OUTPUTS) throw new RangeError("Too many Inline Protocol outputs")
        madeProgress = true
      }
    }
    return { responses, applicationTasks }
  }

  async #handleLogicalConcurrent(
    message: LogicalMessage,
    prepared?: PreparedLogicalMessage,
    completionMessageIds: readonly bigint[] = [message.messageId],
  ): Promise<LogicalHandlingResult> {
    const constructor = prepared?.constructor ?? serviceConstructor(message.body)
    const contentRelated = prepared?.contentRelated ?? this.#isContentRelated(constructor)
    const allowDuplicate = constructor === BindingConstructor.bindTempAuthKey ||
      constructor === ServiceConstructor.gzipPacked ||
      constructor === ServiceConstructor.msgCopy ||
      constructor === INLINE_INVOKE_CONSTRUCTOR
    const duplicate = prepared?.duplicate ?? this.#receivedIds.has(message.messageId)
    if (!prepared) {
      const validation = this.#validateLogical(message, contentRelated, allowDuplicate)
      if (validation !== undefined) {
        return {
          result: {
            responses: [this.#encryptOutgoing(
              encodeBadMsgNotification(message.messageId, message.sequenceNumber, validation), false, 1,
            )],
            applicationTasks: [],
          },
          completed: true,
        }
      }
      if (contentRelated) this.#acknowledgements.add(message.messageId)
    }
    if (duplicate && !allowDuplicate) {
      return { result: { responses: [], applicationTasks: [] }, completed: true }
    }

    if (constructor === ServiceConstructor.gzipPacked) {
      const unpacked = decodeGzipPacked(message.body, this.options.gunzip)
      const unpackedMessage = {
        ...message,
        body: unpacked,
        authenticatedBody: message.authenticatedBody ?? message.body,
      }
      return this.#handleLogicalConcurrent(unpackedMessage, {
        message: unpackedMessage,
        constructor: serviceConstructor(unpacked),
        contentRelated,
        duplicate,
        dependencies: prepared?.dependencies ?? [],
      }, completionMessageIds)
    }
    if (constructor === ServiceConstructor.msgCopy) {
      const copied = decodeMsgCopy(message.body)
      return this.#handleLogicalConcurrent({
        ...copied,
        authenticatedBody: copied.body,
      }, undefined, [...completionMessageIds, copied.messageId])
    }
    if (constructor === INLINE_INVOKE_CONSTRUCTOR) {
      return this.#acceptApplication(message, completionMessageIds)
    }

    return {
      result: {
        responses: await this.#handleLogical(message, prepared),
        applicationTasks: [],
      },
      completed: true,
    }
  }

  async #handleLogical(
    message: LogicalMessage,
    prepared?: PreparedLogicalMessage,
  ): Promise<Uint8Array[]> {
    const constructor = prepared?.constructor ?? serviceConstructor(message.body)
    const contentRelated = prepared?.contentRelated ?? this.#isContentRelated(constructor)
    const allowDuplicate = constructor === BindingConstructor.bindTempAuthKey ||
      constructor === ServiceConstructor.gzipPacked ||
      constructor === ServiceConstructor.msgCopy ||
      constructor === INLINE_INVOKE_CONSTRUCTOR
    const duplicate = prepared?.duplicate ?? this.#receivedIds.has(message.messageId)
    if (!prepared) {
      const validation = this.#validateLogical(message, contentRelated, allowDuplicate)
      if (validation !== undefined) {
        return [this.#encryptOutgoing(
          encodeBadMsgNotification(message.messageId, message.sequenceNumber, validation), false, 1,
        )]
      }
    }
    if (contentRelated) this.#acknowledgements.add(message.messageId)
    if (duplicate && !allowDuplicate) return []

    switch (constructor) {
      case ServiceConstructor.msgsAck:
        this.#pending.acknowledge(decodeMsgsAck(message.body))
        return []
      case ServiceConstructor.msgResendReq: {
        const messageIds = decodeMsgResendReq(message.body)
        const pendingMessages = this.#pending.resend(messageIds)
        if (pendingMessages.length !== messageIds.length) {
          return [this.#encryptOutgoing(
            encodeMsgsStateInfo(message.messageId, this.#pending.state(messageIds)),
            false,
            1,
          )]
        }
        return pendingMessages.map((pending) => this.#encryptOutgoing(
          pending.body,
          pending.sequenceNumber % 2 === 1,
          1,
          pending.messageId,
          pending.sequenceNumber,
        ))
      }
      case ServiceConstructor.msgsStateReq: {
        const ids = decodeMsgsStateReq(message.body)
        const states = Uint8Array.from(ids, (id) => this.#receivedIds.has(id) ? 0x04 : 0x01)
        return [this.#encryptOutgoing(encodeMsgsStateInfo(message.messageId, states), false, 1)]
      }
      case ServiceConstructor.msgsAllInfo: {
        const { messageIds, states } = decodeMsgsAllInfo(message.body)
        this.#pending.acknowledge(messageIds.filter((_, index) => {
          const state = states[index]!
          return (state & 0x07) === 0x04 || (state & 0x80) !== 0
        }))
        return []
      }
      case ServiceConstructor.ping:
      case ServiceConstructor.pingDelayDisconnect: {
        if (message.body.length !== (constructor === ServiceConstructor.ping ? 12 : 16)) throw new RangeError("Invalid ping")
        return [this.#encryptOutgoing(encodePong(message.messageId, readInt64LE(message.body, 4)), false, 1)]
      }
      case ServiceConstructor.httpWait:
        decodeHttpWait(message.body)
        if (this.options.carrierProfile !== "http") {
          throw new RangeError("HTTP wait is invalid outside the HTTP carrier profile")
        }
        return []
      case ServiceConstructor.rpcDropAnswer: {
        const requestMessageId = decodeRpcDropAnswer(message.body)
        const dropped = this.#pending.dropRpcResult(requestMessageId)
        if (dropped) {
          await this.options.replay.forgetAnswer({
            authKeyId: this.#authorization!.keyId,
            sessionId: this.#sessionId!,
            messageId: requestMessageId,
            forgottenResultBody: encodeRpcResult(
              requestMessageId,
              encodeRpcDropAnswerResult({ kind: "unknown" }),
            ),
          })
        }
        const status = dropped
          ? {
            kind: "dropped" as const,
            messageId: dropped.messageId,
            sequenceNumber: dropped.sequenceNumber,
            bytes: dropped.body.length,
          }
          : await this.options.replay.dropAnswer({
            authKeyId: this.#authorization!.keyId,
            sessionId: this.#sessionId!,
            messageId: requestMessageId,
            runningResultBody: encodeRpcResult(
              requestMessageId,
              encodeRpcDropAnswerResult({ kind: "running" }),
            ),
          }) === "running"
            ? { kind: "running" as const }
            : { kind: "unknown" as const }
        if (status.kind === "running") this.#droppedApplicationAnswers.add(requestMessageId)
        return [this.#encryptOutgoing(encodeRpcResult(
          message.messageId,
          encodeRpcDropAnswerResult(status),
        ), true, 1)]
      }
      case ServiceConstructor.gzipPacked: {
        const unpacked = decodeGzipPacked(message.body, this.options.gunzip)
        return this.#handleLogical({
          ...message,
          body: unpacked,
          authenticatedBody: message.authenticatedBody ?? message.body,
        })
      }
      case ServiceConstructor.msgCopy: {
        const copied = decodeMsgCopy(message.body)
        return this.#handleLogical({
          ...copied,
          authenticatedBody: copied.body,
        })
      }
      case ServiceConstructor.getFutureSalts: {
        decodeGetFutureSalts(message.body)
        const now = Math.floor(this.options.nowMilliseconds() / 1000)
        const newSalt = readInt64LE(this.options.randomBytes(8), 0)
        const response = this.#encryptOutgoing(encodeFutureSalts(message.messageId, now, [{
          validSince: now,
          validUntil: now + 30 * 60,
          salt: newSalt,
        }]), true, 1)
        if (!await this.options.authorizationKeys.rotateServerSalt(this.#authorization!.keyId, newSalt)) {
          throw new RangeError("Authorization key disappeared during salt rotation")
        }
        this.#authorization!.previousServerSalt = this.#authorization!.currentServerSalt
        this.#authorization!.currentServerSalt = newSalt
        return [response]
      }
      case ServiceConstructor.destroySession: {
        const target = decodeDestroySession(message.body)
        const found = target === this.#sessionId
        const response = this.#encryptOutgoing(encodeDestroySessionResult(target, found), true, 1)
        if (found) this.#destroyed = true
        return [response]
      }
      case ServiceConstructor.destroyAuthKey: {
        if (message.body.length !== 4) throw new RangeError("Invalid destroy-auth-key request")
        const revoked = await this.options.authorizationKeys.revoke(this.#authorization!.keyId)
        const response = this.#encryptOutgoing(encodeDestroyAuthKeyResult(revoked ? "ok" : "none"), true, 1)
        if (revoked) this.#destroyed = true
        return [response]
      }
      case BindingConstructor.bindTempAuthKey:
        return [await this.#bindTemporary(message)]
      default:
        return this.#dispatchApplication(message)
    }
  }

  async #bindTemporary(message: LogicalMessage): Promise<Uint8Array> {
    const temporary = this.#authorization
    if (!temporary?.temporary || temporary.binding || temporary.expiresAt === undefined || this.#sessionId === undefined) {
      throw new RangeError("Temporary-key binding is not allowed")
    }
    const request = decodeBindTempAuthKey(message.body)
    const permanentId = int64LE(request.permanentAuthKeyId)
    const permanent = await this.options.authorizationKeys.load(permanentId)
    if (!permanent || permanent.temporary || !permanent.authorized) {
      this.#destroyed = true
      throw new InlineProtocolAuthorizationInvalidated()
    }
    verifyTemporaryKeyBindingProof({
      encryptedMessage: request.encryptedMessage,
      permanentAuthKey: permanent.key,
      outerPermanentAuthKeyId: request.permanentAuthKeyId,
      outerTemporaryAuthKeyId: new DataView(temporary.keyId.buffer, temporary.keyId.byteOffset, 8).getBigInt64(0, true),
      outerTemporarySessionId: this.#sessionId,
      outerMessageId: message.messageId,
      outerNonce: request.nonce,
      outerExpiresAt: request.expiresAt,
      temporaryKeyExpiresAt: temporary.expiresAt,
      nowSeconds: Math.floor(this.options.nowMilliseconds() / 1000),
    })
    const result = await this.options.authorizationKeys.bindTemporary({
      temporaryAuthKeyId: temporary.keyId,
      permanentAuthKeyId: permanent.keyId,
      temporarySessionId: this.#sessionId,
      nonce: request.nonce,
      expiresAt: request.expiresAt,
      userId: permanent.authorized.userId,
      accountSessionId: permanent.authorized.accountSessionId,
    })
    if (result === "conflict") throw new RangeError("Temporary-key binding conflicts")
    temporary.binding = {
      permanentAuthKeyId: permanent.keyId.slice(),
      temporarySessionId: this.#sessionId,
      nonce: request.nonce,
      expiresAt: request.expiresAt,
      userId: permanent.authorized.userId,
      accountSessionId: permanent.authorized.accountSessionId,
    }
    return this.#encryptOutgoing(encodeRpcResult(message.messageId, uint32LE(BOOL_TRUE)), true, 1)
  }

  async #acceptApplication(
    message: LogicalMessage,
    completionMessageIds: readonly bigint[] = [message.messageId],
  ): Promise<LogicalHandlingResult> {
    const activeAuthorization = this.#authorization
    const sessionId = this.#sessionId
    if (!activeAuthorization || sessionId === undefined) throw new InvalidEncryptedRecord()
    const authorization = await this.options.authorizationKeys.load(activeAuthorization.keyId)
    if (!authorization) {
      this.#destroyed = true
      throw new InlineProtocolAuthorizationInvalidated()
    }
    if (!equalBytes(authorization.keyId, activeAuthorization.keyId) || this.#sessionId !== sessionId) {
      throw new InvalidEncryptedRecord()
    }
    this.#authorization = authorization
    if (authorization.temporary && !authorization.binding) {
      throw new RangeError("Authorization-key state does not permit application dispatch")
    }
    const application = decodeInlineApplicationObject(message.body)
    if (application.kind !== "invoke" || application.layer !== INLINE_REALTIME_LAYER) {
      throw new RangeError("Invalid Inline application request")
    }
    const replay = await this.options.replay.claim({
      authKeyId: authorization.keyId,
      sessionId,
      messageId: message.messageId,
      authenticatedBody: message.authenticatedBody ?? message.body,
    })
    if (replay.kind === "digest_mismatch") throw new RangeError("Replay digest mismatch")
    if (replay.kind === "completed") {
      return {
        result: {
          responses: [this.#encryptOutgoing(replay.resultBody, true, 1)],
          applicationTasks: [],
        },
        completed: true,
      }
    }
    if (replay.kind === "in_flight") {
      return {
        result: {
          responses: [this.#encryptOutgoing(
            encodeMsgsStateInfo(message.messageId, Uint8Array.of(0x04)), false, 1,
          )],
          applicationTasks: [],
        },
        completed: false,
      }
    }

    if (this.#inFlightApplications.size >= MAX_IN_FLIGHT_APPLICATIONS) {
      const resultBody = encodeRpcResult(
        message.messageId,
        encodeRpcError(503, "Realtime application capacity exceeded"),
      )
      const completion = await this.options.replay.complete({
        authKeyId: authorization.keyId,
        sessionId,
        messageId: message.messageId,
        resultBody,
      })
      return {
        result: {
          responses: [this.#encryptOutgoing(
            completion.kind === "completed" ? resultBody : completion.resultBody,
            true,
            1,
          )],
          applicationTasks: [],
        },
        completed: true,
      }
    }

    const applicationAuthorization: ServerApplicationAuthorization = {
      authKeyId: authorization.keyId.slice(),
      permanentAuthKeyId: authorization.temporary
        ? authorization.binding?.permanentAuthKeyId.slice()
        : authorization.keyId.slice(),
      permanent: !authorization.temporary,
      temporaryBound: authorization.binding !== undefined,
      userId: authorization.temporary ? authorization.binding?.userId : authorization.authorized?.userId,
      accountSessionId: authorization.temporary
        ? authorization.binding?.accountSessionId
        : authorization.authorized?.accountSessionId,
    }
    this.#inFlightApplications.add(message.messageId)
    let didDispatch = false
    const task: InlineProtocolServerApplicationTask = {
      messageId: message.messageId,
      dispatch: async () => {
        if (didDispatch) throw new RangeError("Application task was already dispatched")
        didDispatch = true
        const updates: Uint8Array[] = []
        let updateBytes = 0
        const applicationUpdateReleases: Array<() => void> = []
        let acceptingUpdates = true
        let executionStarted = false
        const controller = new AbortController()
        let timeout: ReturnType<typeof setTimeout> | undefined
        let applicationRelease: (() => void) | undefined
        const makeSettlement = (
          dispatched: Awaited<ReturnType<ServerApplicationDispatcher["dispatch"]>>,
          includeResult: boolean,
        ): InlineProtocolServerApplicationCompletion => {
          let didFinalize = false
          return {
            messageId: message.messageId,
            finalize: async () => {
              if (didFinalize) throw new RangeError("Application completion was already finalized")
              didFinalize = true
              return this.#finalizeApplication({
                authKeyId: authorization.keyId.slice(),
                sessionId,
                messageId: message.messageId,
                completionMessageIds,
                dispatched,
                updates,
                includeResult,
                applicationRelease,
                applicationUpdateReleases,
              })
            },
          }
        }
        if (this.options.tryAcquireApplication) {
          applicationRelease = this.options.tryAcquireApplication(applicationAuthorization)
          if (!applicationRelease) {
            acceptingUpdates = false
            return makeSettlement({
              kind: "error",
              code: 503,
              message: "Realtime application capacity exceeded",
            }, true)
          }
        }
        const applicationDispatch = (async (): Promise<{
          kind: "settled"
          dispatched: Awaited<ReturnType<ServerApplicationDispatcher["dispatch"]>>
        }> => {
          try {
            const dispatched = await this.options.application.dispatch({
              payload: application.payload.slice(),
              authorization: applicationAuthorization,
              messageId: message.messageId,
              sessionId,
              signal: controller.signal,
              markExecutionStarted: () => { executionStarted = true },
              sendUpdate: (payload) => {
                if (!acceptingUpdates) return
                if (updates.length >= MAX_SESSION_OUTPUTS - 1 || updateBytes + payload.length > MAX_PACKET_BYTES) {
                  throw new InlineProtocolApplicationOutputOverloaded()
                }
                const updateRelease = this.options.tryReserveApplicationUpdateBytes?.(payload.length)
                if (this.options.tryReserveApplicationUpdateBytes && !updateRelease) {
                  throw new InlineProtocolApplicationOutputOverloaded()
                }
                try {
                  const copy = payload.slice()
                  updates.push(copy)
                  updateBytes += copy.length
                  if (updateRelease) applicationUpdateReleases.push(updateRelease)
                } catch (error) {
                  updateRelease?.()
                  throw error
                }
              },
            })
            return { kind: "settled", dispatched }
          } catch (error) {
            updates.length = 0
            updateBytes = 0
            for (const release of applicationUpdateReleases.splice(0)) release()
            return {
              kind: "settled",
              dispatched: error instanceof InlineProtocolApplicationOutputOverloaded
                ? {
                  kind: "error",
                  code: 504,
                  message: "Realtime application output capacity exceeded; commit outcome is unknown",
                }
                : controller.signal.aborted
                ? {
                  kind: "error",
                  code: executionStarted ? 504 : 503,
                  message: executionStarted
                    ? "Realtime application deadline exceeded; commit outcome is unknown"
                    : "Realtime application deadline exceeded before execution",
                }
                : { kind: "error", code: 500, message: "Internal server error" },
            }
          }
        })()
        const applicationDeadline = new Promise<{ kind: "deadline" }>((resolve) => {
          timeout = setTimeout(() => {
            controller.abort()
            resolve({ kind: "deadline" })
          }, this.options.applicationTimeoutMs ?? DEFAULT_APPLICATION_TIMEOUT_MS)
        })
        const first = await Promise.race([applicationDispatch, applicationDeadline])
        if (timeout !== undefined) clearTimeout(timeout)

        if (first.kind === "settled") {
          acceptingUpdates = false
          return makeSettlement(first.dispatched, true)
        }

        let didFinalizeDeadline = false
        return {
          messageId: message.messageId,
          settlement: applicationDispatch.then(({ dispatched }) => {
            acceptingUpdates = false
            return makeSettlement(dispatched, false)
          }),
          finalize: async () => {
            if (didFinalizeDeadline) throw new RangeError("Application deadline was already finalized")
            didFinalizeDeadline = true
            return this.#finalizeApplicationDeadline({
              authKeyId: authorization.keyId.slice(),
              sessionId,
              messageId: message.messageId,
              executionStarted,
            })
          },
        }
      },
    }

    return {
      result: { responses: [], applicationTasks: [task] },
      completed: false,
    }
  }

  async #finalizeApplication(input: {
    authKeyId: Uint8Array
    sessionId: bigint
    messageId: bigint
    completionMessageIds: readonly bigint[]
    dispatched: Awaited<ReturnType<ServerApplicationDispatcher["dispatch"]>>
    updates: Uint8Array[]
    includeResult: boolean
    applicationRelease?: () => void
    applicationUpdateReleases: Array<() => void>
  }): Promise<InlineProtocolServerReceiveResult> {
    try {
      const resultObject = input.dispatched.kind === "result"
        ? encodeInlineResult(input.dispatched.payload)
        : encodeRpcError(input.dispatched.code, input.dispatched.message)
      const resultBody = encodeRpcResult(input.messageId, resultObject)
      const completion = await this.options.replay.complete({
        authKeyId: input.authKeyId,
        sessionId: input.sessionId,
        messageId: input.messageId,
        resultBody,
      })
      const terminateAuthorization = input.dispatched.terminateAuthorization === true
      if (terminateAuthorization) {
        if (this.#destroyed || this.#sessionId !== input.sessionId ||
            !this.#authorization || !equalBytes(this.#authorization.keyId, input.authKeyId)) {
          return { responses: [], applicationTasks: [] }
        }
        const answerDropped = this.#droppedApplicationAnswers.delete(input.messageId)
        const responses = input.includeResult && !answerDropped
          ? [this.#encryptOutgoing(
            completion.kind === "completed" ? resultBody : completion.resultBody,
            true,
            1,
          )]
          : []
        for (const messageId of new Set(input.completionMessageIds)) this.#markCompleted(messageId)
        this.#deferredInvokeAfter.clear()
        this.#destroyed = true
        return { responses, applicationTasks: [] }
      }
      const refreshed = await this.options.authorizationKeys.load(input.authKeyId)
      if (!refreshed) {
        this.#destroyed = true
        return { responses: [], applicationTasks: [] }
      }
      if (this.#destroyed || this.#sessionId !== input.sessionId ||
          !this.#authorization || !equalBytes(this.#authorization.keyId, input.authKeyId)) {
        return { responses: [], applicationTasks: [] }
      }
      this.#authorization = refreshed
      const answerDropped = this.#droppedApplicationAnswers.delete(input.messageId)
      const responses = input.includeResult && !answerDropped
        ? [this.#encryptOutgoing(
          completion.kind === "completed" ? resultBody : completion.resultBody,
          true,
          1,
        )]
        : []
      if (completion.kind === "completed") {
        for (const update of input.updates) responses.push(this.sendApplicationUpdate(update))
      }
      for (const messageId of new Set(input.completionMessageIds)) this.#markCompleted(messageId)
      const deferred = await this.#drainDeferredConcurrent()
      const acknowledgements = this.#acknowledgements.drain()
      if (acknowledgements.length > 0) {
        responses.push(this.#encryptOutgoing(encodeMsgsAck(acknowledgements), false, 1))
      }
      responses.push(...deferred.responses)
      return { responses, applicationTasks: deferred.applicationTasks }
    } finally {
      this.#droppedApplicationAnswers.delete(input.messageId)
      for (const release of input.applicationUpdateReleases.splice(0)) release()
      input.applicationRelease?.()
      this.#inFlightApplications.delete(input.messageId)
    }
  }

  async #finalizeApplicationDeadline(input: {
    authKeyId: Uint8Array
    sessionId: bigint
    messageId: bigint
    executionStarted: boolean
  }): Promise<InlineProtocolServerReceiveResult> {
    if (this.#destroyed || this.#sessionId !== input.sessionId ||
        !this.#authorization || !equalBytes(this.#authorization.keyId, input.authKeyId)) {
      return { responses: [], applicationTasks: [] }
    }
    const deadlineResultBody = encodeRpcResult(
      input.messageId,
      input.executionStarted
        ? encodeRpcError(504, "Realtime application deadline exceeded; commit outcome is unknown")
        : encodeRpcError(503, "Realtime application deadline exceeded before execution"),
    )
    const resultBody = input.executionStarted
      ? deadlineResultBody
      : await this.options.replay.complete({
        authKeyId: input.authKeyId,
        sessionId: input.sessionId,
        messageId: input.messageId,
        resultBody: deadlineResultBody,
      }).then((completion) => completion.kind === "completed"
        ? deadlineResultBody
        : completion.resultBody)
    const answerDropped = this.#droppedApplicationAnswers.delete(input.messageId)
    return {
      responses: answerDropped ? [] : [this.#encryptOutgoing(resultBody, true, 1)],
      applicationTasks: [],
    }
  }

  async #dispatchApplication(message: LogicalMessage): Promise<Uint8Array[]> {
    const accepted = await this.#acceptApplication(message)
    const responses = [...accepted.result.responses]
    const tasks = [...accepted.result.applicationTasks]
    while (tasks.length > 0) {
      const completion = await tasks.shift()!.dispatch()
      const finalized = await completion.finalize()
      responses.push(...finalized.responses)
      tasks.push(...finalized.applicationTasks)
      if (completion.settlement) {
        const settlement = await completion.settlement
        const settled = await settlement.finalize()
        responses.push(...settled.responses)
        tasks.push(...settled.applicationTasks)
      }
    }
    return responses
  }

  #validateLogical(
    message: LogicalMessage,
    contentRelated: boolean,
    allowDuplicate = false,
  ): 16 | 17 | 18 | 20 | 32 | 33 | 34 | 35 | undefined {
    const time = validateInboundMessageId(
      message.messageId,
      "client",
      Math.floor(this.options.nowMilliseconds() / 1000),
    )
    if (time.kind === "bad") return time.errorCode
    if (this.#receivedIds.has(message.messageId)) return allowDuplicate ? undefined : 20
    if (!this.#receivedIds.claim(message.messageId)) return 20
    return this.#receivedSequences.validate(message.messageId, message.sequenceNumber, contentRelated)
  }

  #isContentRelated(constructor: number): boolean {
    return !NON_CONTENT_CONSTRUCTORS.has(constructor)
  }

  #encryptOutgoing(
    body: Uint8Array,
    contentRelated: boolean,
    modulo: 1 | 3,
    fixedMessageId?: bigint,
    fixedSequenceNumber?: number,
  ): Uint8Array {
    const authorization = this.#authorization
    const sessionId = this.#sessionId
    if (!authorization || sessionId === undefined) throw new InvalidEncryptedRecord()
    const messageId = fixedMessageId ?? this.#nextServerMessageId(modulo)
    const sequenceNumber = fixedSequenceNumber ?? (fixedMessageId === undefined
      ? this.#sequenceNumbers.next(contentRelated)
      : contentRelated ? 1 : 0)
    const paddingLength = 12 + ((16 - ((32 + body.length + 12) % 16)) % 16)
    const record = encryptRecord(authorization.key, "server-to-client", {
      serverSalt: authorization.currentServerSalt,
      sessionId,
      messageId,
      sequenceNumber,
      body,
    }, this.options.randomBytes(paddingLength))
    if (contentRelated && fixedMessageId === undefined) this.#pending.retain({ messageId, sequenceNumber, body })
    return record
  }

  #nextServerMessageId(modulo: 1 | 3): bigint {
    const random = this.options.randomBytes(4)
    if (random.length !== 4) throw new RangeError("CSPRNG returned invalid message-ID randomness")
    const lowBits = new DataView(random.buffer, random.byteOffset, 4).getUint32(0, true) & 0x3fffffff
    return this.#messageIds.next(this.options.nowMilliseconds(), lowBits, modulo)
  }
}
