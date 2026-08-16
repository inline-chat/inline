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
  decodeInvokeAfter,
  decodeDestroySession,
  decodeGetFutureSalts,
  decodeMessageContainer,
  decodeMsgCopy,
  decodeMsgResendReq,
  decodeMsgsAck,
  decodeMsgsStateReq,
  encodeBadMsgNotification,
  encodeBadServerSalt,
  encodeDestroyAuthKeyResult,
  encodeDestroySessionResult,
  encodeFutureSalts,
  encodeMsgsAck,
  encodeMsgsStateInfo,
  encodePong,
  encodeNewSessionCreated,
  encodeRpcError,
  encodeRpcResult,
  serviceConstructor,
} from "./service.js"

const BOOL_TRUE = 0x997275b5
const MAX_SESSION_OUTPUTS = 2048
const MAX_COMPLETED_INCOMING_MESSAGES = 8192
const MAX_DEFERRED_INVOKE_AFTER = 1024
const MAX_INVOKE_AFTER_NESTING = 16
const NON_CONTENT_CONSTRUCTORS = new Set<number>([
  ServiceConstructor.msgContainer,
  ServiceConstructor.msgsAck,
  ServiceConstructor.msgResendReq,
  ServiceConstructor.msgsStateReq,
  ServiceConstructor.msgsStateInfo,
  ServiceConstructor.msgsAllInfo,
  ServiceConstructor.ping,
  ServiceConstructor.pingDelayDisconnect,
  ServiceConstructor.pong,
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
    sendUpdate: (payload: Uint8Array) => void
  }): Promise<
    | { kind: "result"; payload: Uint8Array }
    | { kind: "error"; code: number; message: string }
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
  dc?: number
}

export interface InlineProtocolServerReceiveOptions {
  onQuickAck?: (quickAckId: number) => void
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
  readonly #handshake: InlineHandshakeServer
  #authorization: LoadedServerAuthorizationKey | undefined
  #sessionId: bigint | undefined
  #destroyed = false

  constructor(private readonly options: InlineProtocolServerSessionOptions) {
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

  async receive(
    payload: Uint8Array,
    receiveOptions: InlineProtocolServerReceiveOptions = {},
  ): Promise<Uint8Array[]> {
    if (this.#destroyed) throw new InvalidEncryptedRecord()
    if (payload.length < 8 || payload.length > MAX_PACKET_BYTES) throw new InvalidEncryptedRecord()
    if (payload.slice(0, 8).every((byte) => byte === 0)) return [await this.#receiveHandshake(payload)]
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
  ): Promise<Uint8Array[]> {
    const authKeyId = payload.slice(0, 8)
    if (!this.#authorization || bytesToHex(this.#authorization.keyId) !== bytesToHex(authKeyId)) {
      const loaded = await this.options.authorizationKeys.load(authKeyId)
      if (!loaded) throw new InvalidEncryptedRecord()
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
        return [this.#encryptOutgoing(recovery, false, 1)]
      }
      throw error
    }
    const newSession = this.#sessionId === undefined
    this.#sessionId ??= fields.sessionId
    if (fields.sessionId !== this.#sessionId) throw new InvalidEncryptedRecord()

    let messages: LogicalMessage[]
    if (serviceConstructor(fields.body) === ServiceConstructor.msgContainer) {
      const outerError = this.#validateLogical(fields, false, true)
      if (outerError !== undefined) {
        return [this.#encryptOutgoing(
          encodeBadMsgNotification(fields.messageId, fields.sequenceNumber, outerError), false, 1,
        )]
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
        return [this.#encryptOutgoing(
          encodeBadMsgNotification(message.messageId, message.sequenceNumber, validation), false, 1,
        )]
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

    const outputs: Uint8Array[] = []
    if (newSession) {
      const firstContent = prepared.find((item) => item.contentRelated)?.message
      if (firstContent) {
        outputs.push(this.#encryptOutgoing(encodeNewSessionCreated(
          firstContent.messageId,
          readInt64LE(this.options.randomBytes(8), 0),
          authorization.currentServerSalt,
        ), true, 1))
      }
    }
    for (const item of prepared) {
      if (this.#dependenciesComplete(item.dependencies)) {
        outputs.push(...await this.#completePrepared(item))
        outputs.push(...await this.#drainDeferred())
      } else {
        this.#defer(item)
      }
      if (outputs.length > MAX_SESSION_OUTPUTS) throw new RangeError("Too many Inline Protocol outputs")
    }
    const acknowledgements = this.#acknowledgements.drain()
    if (acknowledgements.length > 0) outputs.push(this.#encryptOutgoing(encodeMsgsAck(acknowledgements), false, 1))
    return outputs
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

  async #completePrepared(item: PreparedLogicalMessage): Promise<Uint8Array[]> {
    const outputs = await this.#handleLogical(item.message, item)
    this.#completedIncoming.delete(item.message.messageId)
    this.#completedIncoming.set(item.message.messageId, true)
    if (this.#completedIncoming.size > MAX_COMPLETED_INCOMING_MESSAGES) {
      const oldest = this.#completedIncoming.keys().next().value
      if (oldest !== undefined) this.#completedIncoming.delete(oldest)
    }
    return outputs
  }

  async #drainDeferred(): Promise<Uint8Array[]> {
    const outputs: Uint8Array[] = []
    let madeProgress = true
    while (madeProgress) {
      madeProgress = false
      for (const [messageId, item] of this.#deferredInvokeAfter) {
        if (!this.#dependenciesComplete(item.dependencies)) continue
        this.#deferredInvokeAfter.delete(messageId)
        outputs.push(...await this.#completePrepared(item))
        if (outputs.length > MAX_SESSION_OUTPUTS) throw new RangeError("Too many Inline Protocol outputs")
        madeProgress = true
      }
    }
    return outputs
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
      case ServiceConstructor.msgResendReq:
        return this.#pending.resend(decodeMsgResendReq(message.body)).map((pending) =>
          this.#encryptOutgoing(
            pending.body,
            pending.sequenceNumber % 2 === 1,
            1,
            pending.messageId,
            pending.sequenceNumber,
          ))
      case ServiceConstructor.msgsStateReq: {
        const ids = decodeMsgsStateReq(message.body)
        const states = Uint8Array.from(ids, (id) => this.#receivedIds.has(id) ? 0x04 : 0x01)
        return [this.#encryptOutgoing(encodeMsgsStateInfo(message.messageId, states), false, 1)]
      }
      case ServiceConstructor.ping:
      case ServiceConstructor.pingDelayDisconnect: {
        if (message.body.length !== (constructor === ServiceConstructor.ping ? 12 : 16)) throw new RangeError("Invalid ping")
        return [this.#encryptOutgoing(encodePong(message.messageId, readInt64LE(message.body, 4)), false, 1)]
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
    if (!permanent || permanent.temporary || !permanent.authorized) throw new RangeError("Permanent key is unavailable")
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

  async #dispatchApplication(message: LogicalMessage): Promise<Uint8Array[]> {
    const authorization = await this.options.authorizationKeys.load(this.#authorization!.keyId)
    if (!authorization) {
      this.#destroyed = true
      throw new RangeError("Authorization key is no longer active")
    }
    this.#authorization = authorization
    if ((authorization.temporary && !authorization.binding) ||
        (!authorization.temporary && authorization.authorized)) {
      throw new RangeError("Authorization-key state does not permit application dispatch")
    }
    const application = decodeInlineApplicationObject(message.body)
    if (application.kind !== "invoke" || application.layer !== INLINE_REALTIME_LAYER) {
      throw new RangeError("Invalid Inline application request")
    }
    const replay = await this.options.replay.claim({
      authKeyId: authorization.keyId,
      sessionId: this.#sessionId!,
      messageId: message.messageId,
      authenticatedBody: message.authenticatedBody ?? message.body,
    })
    if (replay.kind === "digest_mismatch") throw new RangeError("Replay digest mismatch")
    if (replay.kind === "completed") return [this.#encryptOutgoing(replay.resultBody, true, 1)]
    if (replay.kind === "in_flight") return [this.#encryptOutgoing(
      encodeMsgsStateInfo(message.messageId, Uint8Array.of(0x04)), false, 1,
    )]
    const updates: Uint8Array[] = []
    const dispatched = await this.options.application.dispatch({
      payload: application.payload,
      authorization: {
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
      },
      messageId: message.messageId,
      sessionId: this.#sessionId!,
      sendUpdate: (payload) => {
        updates.push(this.sendApplicationUpdate(payload))
      },
    })
    const resultObject = dispatched.kind === "result"
      ? encodeInlineResult(dispatched.payload)
      : encodeRpcError(dispatched.code, dispatched.message)
    const resultBody = encodeRpcResult(message.messageId, resultObject)
    await this.options.replay.complete({
      authKeyId: authorization.keyId,
      sessionId: this.#sessionId!,
      messageId: message.messageId,
      resultBody,
    })
    const refreshed = await this.options.authorizationKeys.load(authorization.keyId)
    if (refreshed) this.#authorization = refreshed
    return [this.#encryptOutgoing(resultBody, true, 1), ...updates]
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
