import BigInt
import CommonCrypto
import Foundation
import Security

public struct InlineProtocolRSAPublicKey: Equatable, Sendable {
  public let modulus: [UInt8]
  public let exponent: [UInt8]
  public let fingerprint: Int64

  public init(modulus: [UInt8], exponent: [UInt8], fingerprint: Int64) throws {
    guard try Self.fingerprint(modulus: modulus, exponent: exponent) == fingerprint else {
      throw InlineProtocolError.invalidInput
    }
    self.modulus = modulus
    self.exponent = exponent
    self.fingerprint = fingerprint
  }

  public static func fingerprint(modulus: [UInt8], exponent: [UInt8]) throws -> Int64 {
    guard modulus.count == 256, !exponent.isEmpty else { throw InlineProtocolError.invalidInput }
    let digest = handshakeSHA1(try encodeHandshakeTLBytes(modulus) + encodeHandshakeTLBytes(exponent))
    return readHandshakeInt64(digest, at: 12)
  }
}

public struct InlineProtocolAuthorization: Equatable, Sendable, Codable {
  public let key: [UInt8]
  public let keyID: [UInt8]
  public var serverSalt: Int64
  public let temporary: Bool
  public let expiresAt: Int32?

  public init(key: [UInt8], keyID: [UInt8], serverSalt: Int64, temporary: Bool, expiresAt: Int32?) throws {
    guard key.count == 256, keyID.count == 8, try InlineSecureTransport.authKeyID(key) == keyID
    else { throw InlineProtocolError.invalidInput }
    self.key = key
    self.keyID = keyID
    self.serverSalt = serverSalt
    self.temporary = temporary
    self.expiresAt = expiresAt
  }
}

public enum InlineHandshakeTransition: Equatable, Sendable {
  case request([UInt8])
  case established(authorization: InlineProtocolAuthorization, serverTime: Int32)
}

public final class InlineHandshakeClient {
  public typealias RandomBytes = @Sendable (Int) throws -> [UInt8]

  private enum Phase {
    case idle
    case pq(nonce: [UInt8], temporary: Bool)
    case serverDH(nonce: [UInt8], serverNonce: [UInt8], newNonce: [UInt8], temporary: Bool)
    case result(
      nonce: [UInt8], serverNonce: [UInt8], newNonce: [UInt8], temporary: Bool,
      prime: [UInt8], gA: [UInt8], authKey: [UInt8], retries: Int, serverTime: Int32
    )
    case complete
  }

  private let rsaKeys: [InlineProtocolRSAPublicKey]
  private let randomBytes: RandomBytes
  private let dc: Int32
  private var phase: Phase = .idle

  public init(rsaKeys: [InlineProtocolRSAPublicKey], dc: Int32 = 1, randomBytes: @escaping RandomBytes) {
    self.rsaKeys = rsaKeys
    self.dc = dc
    self.randomBytes = randomBytes
  }

  public convenience init(rsaKeys: [InlineProtocolRSAPublicKey], dc: Int32 = 1) {
    self.init(rsaKeys: rsaKeys, dc: dc) { count in
      var bytes = [UInt8](repeating: 0, count: count)
      guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
        throw InlineProtocolError.invalidInput
      }
      return bytes
    }
  }

  public func begin(temporary: Bool) throws -> [UInt8] {
    guard case .idle = phase else { throw InlineProtocolError.invalidInput }
    let nonce = try requireRandom(16)
    phase = .pq(nonce: nonce, temporary: temporary)
    return littleHandshake(Handshake.reqPQMulti) + nonce
  }

  public func receive(_ body: [UInt8]) throws -> InlineHandshakeTransition {
    switch phase {
    case let .pq(nonce, temporary): try receivePQ(body, nonce: nonce, temporary: temporary)
    case let .serverDH(nonce, serverNonce, newNonce, temporary):
      try receiveServerDH(body, nonce: nonce, serverNonce: serverNonce, newNonce: newNonce, temporary: temporary)
    case let .result(nonce, serverNonce, newNonce, temporary, prime, gA, authKey, retries, serverTime):
      try receiveResult(
        body, nonce: nonce, serverNonce: serverNonce, newNonce: newNonce, temporary: temporary,
        prime: prime, gA: gA, authKey: authKey, retries: retries, serverTime: serverTime
      )
    case .idle, .complete: throw InlineProtocolError.invalidInput
    }
  }

  private func receivePQ(_ body: [UInt8], nonce: [UInt8], temporary: Bool) throws -> InlineHandshakeTransition {
    var reader = try HandshakeReader(body, constructor: Handshake.resPQ)
    guard try reader.fixed(16) == nonce else { throw InlineProtocolError.invalidInput }
    let serverNonce = try reader.fixed(16)
    let pq = try reader.bytes()
    guard try reader.uint32() == Handshake.vector else { throw InlineProtocolError.invalidInput }
    let count = Int(try reader.int32())
    guard (0...64).contains(count) else { throw InlineProtocolError.invalidInput }
    let fingerprints = try (0..<count).map { _ in try reader.int64() }
    try reader.expectEnd()
    guard let key = rsaKeys.first(where: { fingerprints.contains($0.fingerprint) }) else {
      throw InlineProtocolError.invalidInput
    }
    let factors = try factorPQ(pq)
    let newNonce = try requireRandom(32)
    var inner = littleHandshake(temporary ? Handshake.pqInnerTempDC : Handshake.pqInnerDC)
      + (try encodeHandshakeTLBytes(pq))
      + (try encodeHandshakeTLBytes(factors.p))
      + (try encodeHandshakeTLBytes(factors.q))
      + nonce + serverNonce + newNonce + littleHandshake(dc)
    if temporary { inner += littleHandshake(Int32(86_400)) }
    let encrypted = try rsaPad(inner, key: key).encryptedData
    phase = .serverDH(nonce: nonce, serverNonce: serverNonce, newNonce: newNonce, temporary: temporary)
    return .request(
      littleHandshake(Handshake.reqDHParams) + nonce + serverNonce
        + (try encodeHandshakeTLBytes(factors.p)) + (try encodeHandshakeTLBytes(factors.q))
        + littleHandshake(key.fingerprint) + (try encodeHandshakeTLBytes(encrypted))
    )
  }

  private func receiveServerDH(
    _ body: [UInt8], nonce: [UInt8], serverNonce: [UInt8], newNonce: [UInt8], temporary: Bool
  ) throws -> InlineHandshakeTransition {
    let constructor = try readHandshakeUInt32(body, at: 0)
    if constructor == Handshake.serverDHParamsFail {
      guard body.count == 52, Array(body[4..<20]) == nonce, Array(body[20..<36]) == serverNonce,
            Array(body[36..<52]) == Array(handshakeSHA1(newNonce)[4..<20])
      else { throw InlineProtocolError.invalidInput }
      throw InlineProtocolError.invalidInput
    }
    var reader = try HandshakeReader(body, constructor: Handshake.serverDHParamsOK)
    guard try reader.fixed(16) == nonce, try reader.fixed(16) == serverNonce else {
      throw InlineProtocolError.invalidInput
    }
    let encrypted = try reader.bytes()
    try reader.expectEnd()
    let aes = try InlineSecureTransport.deriveTemporaryAES(newNonce: newNonce, serverNonce: serverNonce)
    let plaintext = try InlineSecureTransport.aesIGEDecrypt(encrypted, key: aes.key, iv: aes.iv)
    guard plaintext.count >= 24 else { throw InlineProtocolError.invalidInput }
    var inner = try HandshakeReader(Array(plaintext[20...]), constructor: Handshake.serverDHInner)
    guard try inner.fixed(16) == nonce, try inner.fixed(16) == serverNonce else {
      throw InlineProtocolError.invalidInput
    }
    let generator = try inner.int32()
    let prime = try inner.bytes()
    let gA = try inner.bytes()
    let serverTime = try inner.int32()
    let consumed = 24 + inner.offset
    guard (0...15).contains(plaintext.count - consumed),
          Array(plaintext[0..<20]) == handshakeSHA1(Array(plaintext[20..<consumed]))
    else { throw InlineProtocolError.invalidInput }
    try InlineSecureTransport.validateDHParameters(primeBytes: prime, generator: generator)
    try InlineSecureTransport.validateDHPublicValue(gA, prime: prime)
    return .request(try makeClientDH(
      nonce: nonce, serverNonce: serverNonce, newNonce: newNonce, temporary: temporary,
      prime: prime, gA: gA, retries: 0, retryID: 0, serverTime: serverTime
    ))
  }

  private func makeClientDH(
    nonce: [UInt8], serverNonce: [UInt8], newNonce: [UInt8], temporary: Bool,
    prime: [UInt8], gA: [UInt8], retries: Int, retryID: Int64, serverTime: Int32
  ) throws -> [UInt8] {
    let exponent = try requireRandom(256)
    let gB = try modularPower(base: [3], exponent: exponent, modulus: prime)
    try InlineSecureTransport.validateDHPublicValue(gB, prime: prime)
    let authKey = try modularPower(base: gA, exponent: exponent, modulus: prime)
    let serialized = littleHandshake(Handshake.clientDHInner) + nonce + serverNonce
      + littleHandshake(retryID) + (try encodeHandshakeTLBytes(gB))
    let padding = try requireRandom((16 - (20 + serialized.count) % 16) % 16)
    let encrypted = try InlineSecureTransport.encryptDHInner(
      serialized: serialized, padding: padding, newNonce: newNonce, serverNonce: serverNonce
    )
    phase = .result(
      nonce: nonce, serverNonce: serverNonce, newNonce: newNonce, temporary: temporary,
      prime: prime, gA: gA, authKey: authKey, retries: retries, serverTime: serverTime
    )
    return littleHandshake(Handshake.setClientDHParams) + nonce + serverNonce
      + (try encodeHandshakeTLBytes(encrypted))
  }

  private func receiveResult(
    _ body: [UInt8], nonce: [UInt8], serverNonce: [UInt8], newNonce: [UInt8], temporary: Bool,
    prime: [UInt8], gA: [UInt8], authKey: [UInt8], retries: Int, serverTime: Int32
  ) throws -> InlineHandshakeTransition {
    guard body.count == 52, Array(body[4..<20]) == nonce, Array(body[20..<36]) == serverNonce
    else { throw InlineProtocolError.invalidInput }
    let constructor = try readHandshakeUInt32(body, at: 0)
    let index: UInt8 = switch constructor {
    case Handshake.dhGenOK: 1
    case Handshake.dhGenRetry: 2
    case Handshake.dhGenFail: 3
    default: throw InlineProtocolError.invalidInput
    }
    let auxiliary = Array(handshakeSHA1(authKey)[0..<8])
    guard Array(body[36..<52]) == Array(handshakeSHA1(newNonce + [index] + auxiliary)[4..<20])
    else { throw InlineProtocolError.invalidInput }
    if constructor == Handshake.dhGenFail { throw InlineProtocolError.invalidInput }
    if constructor == Handshake.dhGenRetry {
      guard retries < 4 else { throw InlineProtocolError.invalidInput }
      return .request(try makeClientDH(
        nonce: nonce, serverNonce: serverNonce, newNonce: newNonce, temporary: temporary,
        prime: prime, gA: gA, retries: retries + 1,
        retryID: readHandshakeInt64(auxiliary, at: 0), serverTime: serverTime
      ))
    }
    phase = .complete
    let saltBytes = zip(newNonce.prefix(8), serverNonce.prefix(8)).map(^)
    return .established(
      authorization: try InlineProtocolAuthorization(
        key: authKey,
        keyID: InlineSecureTransport.authKeyID(authKey),
        serverSalt: readHandshakeInt64(saltBytes, at: 0),
        temporary: temporary,
        expiresAt: temporary ? serverTime + 86_400 : nil
      ),
      serverTime: serverTime
    )
  }

  private func factorPQ(_ bytes: [UInt8]) throws -> (p: [UInt8], q: [UInt8]) {
    guard !bytes.isEmpty, bytes.count <= 8 else { throw InlineProtocolError.invalidInput }
    let value = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    guard value > 3, value < 1 << 63 else { throw InlineProtocolError.invalidInput }
    if value.isMultiple(of: 2) { return ([2], minimalBigEndian(value / 2)) }
    for _ in 0..<32 {
      var x = try requireRandom(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % (value - 2) + 2
      var y = x
      let c = try requireRandom(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } % (value - 1) + 1
      var divisor: UInt64 = 1
      for _ in 0..<1_000_000 where divisor == 1 {
        x = (multiplyMod(x, x, value) + c) % value
        y = (multiplyMod(y, y, value) + c) % value
        y = (multiplyMod(y, y, value) + c) % value
        divisor = gcd(x > y ? x - y : y - x, value)
      }
      if divisor > 1, divisor < value {
        let other = value / divisor
        return divisor < other
          ? (minimalBigEndian(divisor), minimalBigEndian(other))
          : (minimalBigEndian(other), minimalBigEndian(divisor))
      }
    }
    throw InlineProtocolError.invalidInput
  }

  private func rsaPad(_ inner: [UInt8], key: InlineProtocolRSAPublicKey) throws -> InlineRSAPadIntermediate {
    guard inner.count <= 144 else { throw InlineProtocolError.invalidInput }
    for _ in 0..<64 {
      do {
        return try InlineSecureTransport.rsaPadAttempt(
          serializedInner: inner,
          randomPadding: requireRandom(192 - inner.count),
          temporaryKey: requireRandom(32),
          modulus: key.modulus,
          exponent: key.exponent
        )
      } catch InlineProtocolError.invalidInput { continue }
    }
    throw InlineProtocolError.invalidInput
  }

  private func modularPower(base: [UInt8], exponent: [UInt8], modulus: [UInt8]) throws -> [UInt8] {
    let value = BigUInt(Data(base)).power(BigUInt(Data(exponent)), modulus: BigUInt(Data(modulus))).serialize()
    guard value.count <= 256 else { throw InlineProtocolError.invalidInput }
    return [UInt8](repeating: 0, count: 256 - value.count) + value
  }

  private func requireRandom(_ count: Int) throws -> [UInt8] {
    let bytes = try randomBytes(count)
    guard bytes.count == count else { throw InlineProtocolError.invalidInput }
    return bytes
  }
}

private enum Handshake {
  static let resPQ: UInt32 = 0x05162463
  static let pqInnerDC: UInt32 = 0xa9f55f95
  static let pqInnerTempDC: UInt32 = 0x56fddf88
  static let serverDHParamsOK: UInt32 = 0xd0e8075c
  static let serverDHParamsFail: UInt32 = 0x79cb045d
  static let serverDHInner: UInt32 = 0xb5890dba
  static let clientDHInner: UInt32 = 0x6643b654
  static let dhGenOK: UInt32 = 0x3bcbf734
  static let dhGenRetry: UInt32 = 0x46dc1fb9
  static let dhGenFail: UInt32 = 0xa69dae02
  static let reqPQMulti: UInt32 = 0xbe7e8ef1
  static let reqDHParams: UInt32 = 0xd712e4be
  static let setClientDHParams: UInt32 = 0xf5045f1f
  static let vector: UInt32 = 0x1cb5c415
}

private struct HandshakeReader {
  let storage: [UInt8]
  var offset = 0

  init(_ body: [UInt8], constructor: UInt32) throws {
    guard try readHandshakeUInt32(body, at: 0) == constructor else { throw InlineProtocolError.invalidInput }
    storage = Array(body.dropFirst(4))
  }

  mutating func fixed(_ count: Int) throws -> [UInt8] {
    guard offset + count <= storage.count else { throw InlineProtocolError.invalidInput }
    defer { offset += count }
    return Array(storage[offset..<(offset + count)])
  }

  mutating func int32() throws -> Int32 { readHandshakeInt32(try fixed(4), at: 0) }
  mutating func uint32() throws -> UInt32 { try readHandshakeUInt32(try fixed(4), at: 0) }
  mutating func int64() throws -> Int64 { readHandshakeInt64(try fixed(8), at: 0) }

  mutating func bytes() throws -> [UInt8] {
    guard offset < storage.count else { throw InlineProtocolError.invalidInput }
    let first = storage[offset]
    let header: Int
    let count: Int
    if first < 254 { header = 1; count = Int(first) }
    else if first == 254, offset + 4 <= storage.count {
      header = 4
      count = Int(storage[offset + 1]) | Int(storage[offset + 2]) << 8 | Int(storage[offset + 3]) << 16
    } else { throw InlineProtocolError.invalidInput }
    let total = (header + count + 3) / 4 * 4
    guard offset + total <= storage.count,
          storage[(offset + header + count)..<(offset + total)].allSatisfy({ $0 == 0 })
    else { throw InlineProtocolError.invalidInput }
    defer { offset += total }
    return Array(storage[(offset + header)..<(offset + header + count)])
  }

  func expectEnd() throws { guard offset == storage.count else { throw InlineProtocolError.invalidInput } }
}

private func encodeHandshakeTLBytes(_ value: [UInt8]) throws -> [UInt8] {
  guard value.count <= 0x00ff_ffff else { throw InlineProtocolError.invalidInput }
  var output = value.count < 254
    ? [UInt8(value.count)] + value
    : [
      254,
      UInt8(value.count & 0xff),
      UInt8((value.count >> 8) & 0xff),
      UInt8((value.count >> 16) & 0xff),
    ] + value
  output += repeatElement(0, count: (4 - output.count % 4) % 4)
  return output
}

private func handshakeSHA1(_ value: [UInt8]) -> [UInt8] {
  var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
  value.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(value.count), &digest) }
  return digest
}

private func littleHandshake<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  withUnsafeBytes(of: value.littleEndian, Array.init)
}

private func readHandshakeUInt32(_ value: [UInt8], at offset: Int) throws -> UInt32 {
  guard offset + 4 <= value.count else { throw InlineProtocolError.invalidInput }
  return value[offset..<(offset + 4)].enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
}

private func readHandshakeInt32(_ value: [UInt8], at offset: Int) -> Int32 {
  Int32(bitPattern: value[offset..<(offset + 4)].enumerated().reduce(0) {
    $0 | UInt32($1.element) << UInt32($1.offset * 8)
  })
}

private func readHandshakeInt64(_ value: [UInt8], at offset: Int) -> Int64 {
  Int64(bitPattern: value[offset..<(offset + 8)].enumerated().reduce(0) {
    $0 | UInt64($1.element) << UInt64($1.offset * 8)
  })
}

private func multiplyMod(_ lhs: UInt64, _ rhs: UInt64, _ modulus: UInt64) -> UInt64 {
  let product = lhs.multipliedFullWidth(by: rhs)
  return modulus.dividingFullWidth(product).remainder
}

private func gcd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
  var a = lhs
  var b = rhs
  while b != 0 { (a, b) = (b, a % b) }
  return a
}

private func minimalBigEndian(_ value: UInt64) -> [UInt8] {
  let bytes = withUnsafeBytes(of: value.bigEndian, Array.init)
  return Array(bytes.drop(while: { $0 == 0 }))
}
