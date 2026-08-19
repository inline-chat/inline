import { aesIgeDecrypt, aesIgeEncrypt, authKeyId, constantTimeEqual, sha1Digest, sha256Digest } from "./crypto.js"
import {
  TELEGRAM_DH_PRIME,
  bindRetryId,
  deriveAuthKey,
  deriveTemporaryAes,
  factorPq,
  initialServerSalt,
  newNonceHash,
  rsaPad,
  rsaPublicKeyFingerprint,
  serverDhFailureHash,
  type RandomBytes,
  validateDhParameters,
  validateDhPublicValue,
} from "./handshake.js"
import {
  decodeClientDhInnerDataPrefix,
  decodeDhGen,
  decodePqInnerDataPrefix,
  decodeReqDhParams,
  decodeReqPqMulti,
  decodeResPq,
  decodeServerDhInnerDataPrefix,
  decodeServerDhParams,
  decodeSetClientDhParams,
  encodeClientDhInnerData,
  encodeDhGen,
  encodePqInnerData,
  encodeReqDhParams,
  encodeReqPqMulti,
  encodeResPq,
  encodeServerDhInnerData,
  encodeServerDhParamsOk,
  encodeSetClientDhParams,
} from "./handshakeSchema.js"
import { concatBytes, equalBytes, hexToBytes, xorBytes } from "./bytes.js"

const PQ = hexToBytes("17ed48941a08f981")
const P = hexToBytes("494c553b")
const Q = hexToBytes("53911073")

export interface HandshakeRsaPublicKey {
  modulus: Uint8Array
  exponent: Uint8Array
  fingerprint: bigint
}

export interface HandshakeRsaServerKey extends HandshakeRsaPublicKey {
  rawDecrypt: (ciphertext: Uint8Array) => Uint8Array | Promise<Uint8Array>
}

export interface EstablishedAuthorizationKey {
  key: Uint8Array
  keyId: Uint8Array
  temporary: boolean
  expiresAt?: number
  serverSalt: bigint
}

export interface ServerAuthorizationKeyStore {
  create(key: EstablishedAuthorizationKey): Promise<"created" | "collision">
}

export type ServerHandshakeResult = {
  response: Uint8Array
  established?: EstablishedAuthorizationKey
}

type ServerPhase =
  | { kind: "pq" }
  | { kind: "dh"; nonce: Uint8Array; serverNonce: Uint8Array }
  | {
    kind: "client-dh"
    nonce: Uint8Array; serverNonce: Uint8Array; newNonce: Uint8Array
    exponent: Uint8Array; temporary: boolean; expiresAt?: number; retries: number; expectedRetryId: bigint
  }
  | { kind: "complete" }

export class InlineHandshakeServer {
  #phase: ServerPhase = { kind: "pq" }

  constructor(private readonly configuration: {
    rsaKeys: readonly HandshakeRsaServerKey[]
    randomBytes: RandomBytes
    nowSeconds: () => number
    authorizationKeys: ServerAuthorizationKeyStore
    dc?: number
    generator?: number
  }) {
    if (configuration.rsaKeys.length < 1) throw new RangeError("At least one server RSA key is required")
    validateDhParameters(
      TELEGRAM_DH_PRIME,
      configuration.generator ?? 3,
      configuration.randomBytes,
    )
  }

  async receive(body: Uint8Array): Promise<ServerHandshakeResult> {
    switch (this.#phase.kind) {
      case "pq": return this.#receivePq(body)
      case "dh": return this.#receiveDh(body, this.#phase)
      case "client-dh": return this.#receiveClientDh(body, this.#phase)
      case "complete": throw new RangeError("Authorization-key handshake is already complete")
    }
  }

  #receivePq(body: Uint8Array): ServerHandshakeResult {
    const { nonce } = decodeReqPqMulti(body)
    const serverNonce = this.configuration.randomBytes(16)
    if (serverNonce.length !== 16) throw new RangeError("CSPRNG returned an invalid nonce")
    this.#phase = { kind: "dh", nonce, serverNonce }
    return {
      response: encodeResPq(nonce, serverNonce, PQ, this.configuration.rsaKeys.map((key) => key.fingerprint)),
    }
  }

  async #receiveDh(body: Uint8Array, phase: Extract<ServerPhase, { kind: "dh" }>): Promise<ServerHandshakeResult> {
    const request = decodeReqDhParams(body)
    this.#requireNonceChain(request.nonce, request.serverNonce, phase.nonce, phase.serverNonce)
    if (!equalBytes(request.p, P) || !equalBytes(request.q, Q)) throw new RangeError("Invalid pq factorization")
    const rsaKey = this.configuration.rsaKeys.find((key) => key.fingerprint === request.fingerprint)
    if (!rsaKey) throw new RangeError("Unknown RSA fingerprint")
    const decrypted = await rsaKey.rawDecrypt(request.encryptedData)
    if (decrypted.length !== 256) throw new RangeError("Invalid raw RSA result")
    const aesEncrypted = decrypted.slice(32)
    const temporaryKey = xorBytes(decrypted.slice(0, 32), sha256Digest(aesEncrypted))
    const dataWithHash = aesIgeDecrypt(aesEncrypted, temporaryKey, new Uint8Array(32))
    const padded = dataWithHash.slice(0, 192).reverse()
    if (!constantTimeEqual(dataWithHash.slice(192), sha256Digest(temporaryKey, padded))) {
      throw new RangeError("Invalid RSA_PAD confirmation")
    }
    const decoded = decodePqInnerDataPrefix(padded)
    const inner = decoded.value
    this.#requireNonceChain(inner.nonce, inner.serverNonce, phase.nonce, phase.serverNonce)
    if (!equalBytes(inner.pq, PQ) || !equalBytes(inner.p, P) || !equalBytes(inner.q, Q) || inner.dc !== (this.configuration.dc ?? 1)) {
      throw new RangeError("Invalid P_Q inner binding")
    }
    const now = this.configuration.nowSeconds()
    let expiresAt: number | undefined
    if (inner.temporary) {
      if (inner.expiresIn !== 86_400) throw new RangeError("Temporary authorization key must request 24 hours")
      expiresAt = now + inner.expiresIn
    }
    const exponent = this.configuration.randomBytes(256)
    if (exponent.length !== 256) throw new RangeError("CSPRNG returned an invalid DH exponent")
    const generator = this.configuration.generator ?? 3
    const gA = deriveAuthKey(Uint8Array.of(generator), exponent, TELEGRAM_DH_PRIME)
    validateDhPublicValue(gA, TELEGRAM_DH_PRIME)
    const serialized = encodeServerDhInnerData({
      nonce: phase.nonce, serverNonce: phase.serverNonce, generator,
      prime: TELEGRAM_DH_PRIME, gA, serverTime: now,
    })
    const paddingLength = (16 - ((20 + serialized.length) % 16)) % 16
    const temporary = deriveTemporaryAes(inner.newNonce, phase.serverNonce)
    const encryptedAnswer = aesIgeEncrypt(
      concatBytes(sha1Digest(serialized), serialized, this.configuration.randomBytes(paddingLength)),
      temporary.key,
      temporary.iv,
    )
    this.#phase = {
      kind: "client-dh", nonce: phase.nonce, serverNonce: phase.serverNonce,
      newNonce: inner.newNonce, exponent, temporary: inner.temporary, expiresAt, retries: 0, expectedRetryId: 0n,
    }
    return { response: encodeServerDhParamsOk(phase.nonce, phase.serverNonce, encryptedAnswer) }
  }

  async #receiveClientDh(
    body: Uint8Array,
    phase: Extract<ServerPhase, { kind: "client-dh" }>,
  ): Promise<ServerHandshakeResult> {
    const request = decodeSetClientDhParams(body)
    this.#requireNonceChain(request.nonce, request.serverNonce, phase.nonce, phase.serverNonce)
    const temporary = deriveTemporaryAes(phase.newNonce, phase.serverNonce)
    const plaintext = aesIgeDecrypt(request.encryptedData, temporary.key, temporary.iv)
    const decoded = decodeClientDhInnerDataPrefix(plaintext.slice(20))
    const paddingLength = plaintext.length - 20 - decoded.consumed
    if (paddingLength < 0 || paddingLength > 15 || !constantTimeEqual(plaintext.slice(0, 20), sha1Digest(plaintext.slice(20, 20 + decoded.consumed)))) {
      throw new RangeError("Invalid client DH inner confirmation")
    }
    this.#requireNonceChain(decoded.value.nonce, decoded.value.serverNonce, phase.nonce, phase.serverNonce)
    if (decoded.value.retryId !== phase.expectedRetryId) {
      throw new RangeError("Invalid DH retry identifier")
    }
    validateDhPublicValue(decoded.value.gB, TELEGRAM_DH_PRIME)
    const authKey = deriveAuthKey(decoded.value.gB, phase.exponent, TELEGRAM_DH_PRIME)
    const established: EstablishedAuthorizationKey = {
      key: authKey,
      keyId: authKeyId(authKey),
      temporary: phase.temporary,
      expiresAt: phase.expiresAt,
      serverSalt: initialServerSalt(phase.newNonce, phase.serverNonce),
    }
    const created = await this.configuration.authorizationKeys.create(established)
    if (created === "collision") {
      if (phase.retries >= 4) {
        this.#phase = { kind: "complete" }
        return { response: encodeDhGen("fail", phase.nonce, phase.serverNonce, newNonceHash(phase.newNonce, 3, authKey)) }
      }
      this.#phase = { ...phase, retries: phase.retries + 1, expectedRetryId: bindRetryId(authKey) }
      return { response: encodeDhGen("retry", phase.nonce, phase.serverNonce, newNonceHash(phase.newNonce, 2, authKey)) }
    }
    this.#phase = { kind: "complete" }
    return {
      response: encodeDhGen("ok", phase.nonce, phase.serverNonce, newNonceHash(phase.newNonce, 1, authKey)),
      established,
    }
  }

  #requireNonceChain(actualNonce: Uint8Array, actualServer: Uint8Array, nonce: Uint8Array, serverNonce: Uint8Array): void {
    if (!constantTimeEqual(actualNonce, nonce) || !constantTimeEqual(actualServer, serverNonce)) {
      throw new RangeError("Handshake nonce chain mismatch")
    }
  }
}

type ClientPhase =
  | { kind: "idle" }
  | { kind: "pq"; nonce: Uint8Array; temporary: boolean }
  | {
    kind: "server-dh"; nonce: Uint8Array; serverNonce: Uint8Array; newNonce: Uint8Array
    temporary: boolean; rsaKey: HandshakeRsaPublicKey
  }
  | {
    kind: "dh-result"; nonce: Uint8Array; serverNonce: Uint8Array; newNonce: Uint8Array
    temporary: boolean; generator: number; prime: Uint8Array; gA: Uint8Array; authKey: Uint8Array; exponent: Uint8Array
    retries: number; serverTime: number
  }
  | { kind: "complete" }

export type ClientHandshakeResult =
  | { request: Uint8Array }
  | { established: EstablishedAuthorizationKey; serverTime: number }

export class InlineHandshakeClient {
  #phase: ClientPhase = { kind: "idle" }

  constructor(private readonly configuration: {
    rsaKeys: readonly HandshakeRsaPublicKey[]
    randomBytes: RandomBytes
    dc?: number
  }) {}

  begin(temporary: boolean): Uint8Array {
    if (this.#phase.kind !== "idle") throw new RangeError("Handshake already started")
    const nonce = this.configuration.randomBytes(16)
    this.#phase = { kind: "pq", nonce, temporary }
    return encodeReqPqMulti(nonce)
  }

  receive(body: Uint8Array): ClientHandshakeResult {
    const phase = this.#phase
    this.#phase = { kind: "complete" }
    switch (phase.kind) {
      case "pq": return { request: this.#receivePq(body, phase) }
      case "server-dh": return { request: this.#receiveServerDh(body, phase) }
      case "dh-result": return this.#receiveDhResult(body, phase)
      case "idle": throw new RangeError("Handshake has not started")
      case "complete": throw new RangeError("Handshake is already complete")
    }
  }

  #receivePq(body: Uint8Array, phase: Extract<ClientPhase, { kind: "pq" }>): Uint8Array {
    const response = decodeResPq(body)
    if (!constantTimeEqual(response.nonce, phase.nonce)) throw new RangeError("Handshake nonce mismatch")
    const rsaKey = this.configuration.rsaKeys.find((key) => response.fingerprints.includes(key.fingerprint))
    if (!rsaKey) throw new RangeError("Server offered no active RSA key")
    const factors = factorPq(response.pq, this.configuration.randomBytes)
    const newNonce = this.configuration.randomBytes(32)
    const inner = encodePqInnerData({
      temporary: phase.temporary, pq: response.pq, p: factors.p, q: factors.q,
      nonce: phase.nonce, serverNonce: response.serverNonce, newNonce,
      dc: this.configuration.dc ?? 1, expiresIn: phase.temporary ? 86_400 : undefined,
    })
    const encryptedData = rsaPad(inner, rsaKey.modulus, rsaKey.exponent, this.configuration.randomBytes).encryptedData
    this.#phase = {
      kind: "server-dh", nonce: phase.nonce, serverNonce: response.serverNonce,
      newNonce, temporary: phase.temporary, rsaKey,
    }
    return encodeReqDhParams({
      nonce: phase.nonce, serverNonce: response.serverNonce, p: factors.p, q: factors.q,
      fingerprint: rsaKey.fingerprint, encryptedData,
    })
  }

  #receiveServerDh(body: Uint8Array, phase: Extract<ClientPhase, { kind: "server-dh" }>): Uint8Array {
    const response = decodeServerDhParams(body)
    this.#requireNonceChain(response.nonce, response.serverNonce, phase.nonce, phase.serverNonce)
    if (response.kind === "fail") {
      if (!constantTimeEqual(response.newNonceHash, serverDhFailureHash(phase.newNonce))) {
        throw new RangeError("Invalid server DH failure confirmation")
      }
      this.#phase = { kind: "complete" }
      throw new RangeError("Server rejected DH parameters")
    }
    const temporary = deriveTemporaryAes(phase.newNonce, phase.serverNonce)
    const plaintext = aesIgeDecrypt(response.encryptedAnswer, temporary.key, temporary.iv)
    const decoded = decodeServerDhInnerDataPrefix(plaintext.slice(20))
    const paddingLength = plaintext.length - 20 - decoded.consumed
    if (paddingLength < 0 || paddingLength > 15 || !constantTimeEqual(plaintext.slice(0, 20), sha1Digest(plaintext.slice(20, 20 + decoded.consumed)))) {
      throw new RangeError("Invalid server DH inner confirmation")
    }
    const inner = decoded.value
    this.#requireNonceChain(inner.nonce, inner.serverNonce, phase.nonce, phase.serverNonce)
    validateDhParameters(inner.prime, inner.generator, this.configuration.randomBytes)
    validateDhPublicValue(inner.gA, inner.prime)
    return this.#makeClientDhRequest({
      nonce: phase.nonce, serverNonce: phase.serverNonce, newNonce: phase.newNonce,
      temporary: phase.temporary, generator: inner.generator, prime: inner.prime, gA: inner.gA,
      retries: 0, retryId: 0n, serverTime: inner.serverTime,
    })
  }

  #makeClientDhRequest(value: {
    nonce: Uint8Array; serverNonce: Uint8Array; newNonce: Uint8Array; temporary: boolean
    generator: number; prime: Uint8Array; gA: Uint8Array; retries: number; retryId: bigint; serverTime: number
  }): Uint8Array {
    const exponent = this.configuration.randomBytes(256)
    const gB = deriveAuthKey(Uint8Array.of(value.generator), exponent, value.prime)
    validateDhPublicValue(gB, value.prime)
    const authKey = deriveAuthKey(value.gA, exponent, value.prime)
    const serialized = encodeClientDhInnerData({
      nonce: value.nonce, serverNonce: value.serverNonce, retryId: value.retryId, gB,
    })
    const paddingLength = (16 - ((20 + serialized.length) % 16)) % 16
    const temporary = deriveTemporaryAes(value.newNonce, value.serverNonce)
    const encrypted = aesIgeEncrypt(
      concatBytes(sha1Digest(serialized), serialized, this.configuration.randomBytes(paddingLength)),
      temporary.key,
      temporary.iv,
    )
    this.#phase = { kind: "dh-result", ...value, exponent, authKey }
    return encodeSetClientDhParams(value.nonce, value.serverNonce, encrypted)
  }

  #receiveDhResult(body: Uint8Array, phase: Extract<ClientPhase, { kind: "dh-result" }>): ClientHandshakeResult {
    const response = decodeDhGen(body)
    this.#requireNonceChain(response.nonce, response.serverNonce, phase.nonce, phase.serverNonce)
    const index = response.kind === "ok" ? 1 : response.kind === "retry" ? 2 : 3
    if (!constantTimeEqual(response.nonceHash, newNonceHash(phase.newNonce, index, phase.authKey))) {
      throw new RangeError("Invalid DH generation confirmation")
    }
    if (response.kind === "fail") throw new RangeError("Server rejected authorization key")
    if (response.kind === "retry") {
      if (phase.retries >= 4) throw new RangeError("Authorization-key retry limit exceeded")
      return { request: this.#makeClientDhRequest({
        nonce: phase.nonce, serverNonce: phase.serverNonce, newNonce: phase.newNonce,
        temporary: phase.temporary, generator: phase.generator, prime: phase.prime, gA: phase.gA,
        retries: phase.retries + 1, retryId: bindRetryId(phase.authKey), serverTime: phase.serverTime,
      }) }
    }
    this.#phase = { kind: "complete" }
    return {
      established: {
        key: phase.authKey,
        keyId: authKeyId(phase.authKey),
        temporary: phase.temporary,
        expiresAt: phase.temporary ? phase.serverTime + 86_400 : undefined,
        serverSalt: initialServerSalt(phase.newNonce, phase.serverNonce),
      },
      serverTime: phase.serverTime,
    }
  }

  #requireNonceChain(actualNonce: Uint8Array, actualServer: Uint8Array, nonce: Uint8Array, serverNonce: Uint8Array): void {
    if (!constantTimeEqual(actualNonce, nonce) || !constantTimeEqual(actualServer, serverNonce)) {
      throw new RangeError("Handshake nonce chain mismatch")
    }
  }
}

export const makeRsaPublicKey = (modulus: Uint8Array, exponent: Uint8Array): HandshakeRsaPublicKey => ({
  modulus,
  exponent,
  fingerprint: rsaPublicKeyFingerprint(modulus, exponent),
})
