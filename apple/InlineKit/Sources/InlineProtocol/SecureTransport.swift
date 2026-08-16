import CommonCrypto
import Foundation
import Security

public enum InlineProtocolError: Error, Equatable, Sendable {
  case invalidEncryptedRecord
  case invalidInput
}

public enum InlineProtocolDirection: Sendable {
  case clientToServer
  case serverToClient

  fileprivate var kdfOffset: Int {
    switch self {
    case .clientToServer: 0
    case .serverToClient: 8
    }
  }
}

public struct InlineEncryptedRecordFields: Equatable, Sendable {
  public let serverSalt: Int64
  public let sessionID: Int64
  public let messageID: Int64
  public let sequenceNumber: Int32
  public let body: [UInt8]

  public init(
    serverSalt: Int64,
    sessionID: Int64,
    messageID: Int64,
    sequenceNumber: Int32,
    body: [UInt8]
  ) {
    self.serverSalt = serverSalt
    self.sessionID = sessionID
    self.messageID = messageID
    self.sequenceNumber = sequenceNumber
    self.body = body
  }
}

public struct InlineRSAPadIntermediate: Equatable, Sendable {
  public let dataWithPadding: [UInt8]
  public let dataWithHash: [UInt8]
  public let aesEncrypted: [UInt8]
  public let keyAESEncrypted: [UInt8]
  public let encryptedData: [UInt8]
}

public enum InlineApplicationObject: Equatable, Sendable {
  case invoke(layer: Int32, payload: [UInt8])
  case result(payload: [UInt8])
  case update(payload: [UInt8])
}

public enum InlineAbridgedFrame: Equatable, Sendable {
  case packet(payload: [UInt8], quickAckRequested: Bool)
  case quickAck(id: UInt32)
}

public struct InlineInvokeAfter: Equatable, Sendable {
  public let messageIDs: [Int64]
  public let query: [UInt8]

  public init(messageIDs: [Int64], query: [UInt8]) {
    self.messageIDs = messageIDs
    self.query = query
  }
}

public enum InlineSecureTransport {
  public static let maximumPacketBytes = 16 * 1024 * 1024
  public static let resultConstructor: UInt32 = 0xac3ddc54
  public static let updateConstructor: UInt32 = 0xdc412c98
  public static let invokeConstructor: UInt32 = 0xeb7d4aa6
  public static let invokeAfterMessageConstructor: UInt32 = 0xcb9f372d
  public static let invokeAfterMessagesConstructor: UInt32 = 0x3dc4b4f0
  private static let vectorConstructor: UInt32 = 0x1cb5c415
  private static let maximumInvokeAfterDependencies = 8_192
  public static let realtimeLayer: Int32 = 3
  public static let telegramDHPrime: [UInt8] = hexBytes(
    "c71caeb9c6b1c9048e6c522f70f13f73980d40238e3e21c14934d037563d930f" +
      "48198a0aa7c14058229493d22530f4dbfa336f6e0ac925139543aed44cce7c372" +
      "0fd51f69458705ac68cd4fe6b6b13abdc9746512969328454f18faf8c595f642" +
      "477fe96bb2a941d5bcd1d4ac8cc49880708fa9b378e3c4f3a9060bee67cf9a4a" +
      "4a695811051907e162753b56b0f6b410dba74d8a84b2a14b3144e0ef1284754f" +
      "d17ed950d5965b4b9dd46582db1178d169c6bc465b0d6ff9ca3928fef5b9ae4e" +
      "418fc15e83ebea0f87fa9ff5eed70050ded2849f47bf959d956850ce929851f0d" +
      "8115f635b105ee2e4e15d04b2454bf6f4fadf034b10403119cd8e3b92fcc5b"
  )

  public static func rsaPadAttempt(
    serializedInner: [UInt8],
    randomPadding: [UInt8],
    temporaryKey: [UInt8],
    modulus: [UInt8],
    exponent: [UInt8]
  ) throws -> InlineRSAPadIntermediate {
    guard serializedInner.count <= 144,
          serializedInner.count + randomPadding.count == 192,
          temporaryKey.count == 32,
          modulus.count == 256,
          !exponent.isEmpty
    else { throw InlineProtocolError.invalidInput }
    let dataWithPadding = serializedInner + randomPadding
    let dataWithHash = Array(dataWithPadding.reversed()) + sha256(temporaryKey + dataWithPadding)
    let aesEncrypted = try aesIGEEncrypt(Array(dataWithHash), key: temporaryKey, iv: [UInt8](repeating: 0, count: 32))
    let keyAESEncrypted = xor(temporaryKey, sha256(aesEncrypted)) + aesEncrypted
    guard lexicographicallyLess(keyAESEncrypted, modulus) else { throw InlineProtocolError.invalidInput }
    let publicKey = try rsaPublicKey(modulus: modulus, exponent: exponent)
    var error: Unmanaged<CFError>?
    guard let encrypted = SecKeyCreateEncryptedData(
      publicKey,
      .rsaEncryptionRaw,
      Data(keyAESEncrypted) as CFData,
      &error
    ) as Data? else {
      if let error { throw error.takeRetainedValue() }
      throw InlineProtocolError.invalidInput
    }
    let encryptedData = [UInt8](encrypted)
    guard encryptedData.count == 256 else { throw InlineProtocolError.invalidInput }
    return InlineRSAPadIntermediate(
      dataWithPadding: dataWithPadding,
      dataWithHash: Array(dataWithHash),
      aesEncrypted: aesEncrypted,
      keyAESEncrypted: keyAESEncrypted,
      encryptedData: encryptedData
    )
  }

  public static func deriveTemporaryAES(
    newNonce: [UInt8],
    serverNonce: [UInt8]
  ) throws -> (key: [UInt8], iv: [UInt8]) {
    guard newNonce.count == 32, serverNonce.count == 16 else { throw InlineProtocolError.invalidInput }
    let nonceServer = sha1(newNonce + serverNonce)
    let serverNonceHash = sha1(serverNonce + newNonce)
    return (
      nonceServer + Array(serverNonceHash[0..<12]),
      Array(serverNonceHash[12..<20]) + sha1(newNonce + newNonce) + Array(newNonce[0..<4])
    )
  }

  public static func encryptDHInner(
    serialized: [UInt8],
    padding: [UInt8],
    newNonce: [UInt8],
    serverNonce: [UInt8]
  ) throws -> [UInt8] {
    guard padding.count <= 15, (20 + serialized.count + padding.count).isMultiple(of: 16)
    else { throw InlineProtocolError.invalidInput }
    let temporary = try deriveTemporaryAES(newNonce: newNonce, serverNonce: serverNonce)
    return try aesIGEEncrypt(sha1(serialized) + serialized + padding, key: temporary.key, iv: temporary.iv)
  }

  public static func decryptDHInner(
    encrypted: [UInt8],
    serializedLength: Int,
    newNonce: [UInt8],
    serverNonce: [UInt8]
  ) throws -> [UInt8] {
    guard !encrypted.isEmpty, encrypted.count.isMultiple(of: 16), serializedLength >= 4
    else { throw InlineProtocolError.invalidInput }
    let temporary = try deriveTemporaryAES(newNonce: newNonce, serverNonce: serverNonce)
    let plaintext = try aesIGEDecrypt(encrypted, key: temporary.key, iv: temporary.iv)
    let paddingLength = plaintext.count - 20 - serializedLength
    guard (0...15).contains(paddingLength) else { throw InlineProtocolError.invalidInput }
    let serialized = Array(plaintext[20..<(20 + serializedLength)])
    guard constantTimeEqual(Array(plaintext[0..<20]), sha1(serialized)) else { throw InlineProtocolError.invalidInput }
    return serialized
  }

  public static func validateBuiltinDHParameters(prime: [UInt8], generator: Int32) throws {
    guard prime == telegramDHPrime, generator == 3 else { throw InlineProtocolError.invalidInput }
  }

  public static func validateDHPublicValue(_ value: [UInt8], prime: [UInt8]) throws {
    guard !value.isEmpty, value.count <= 256, prime.count == 256 else { throw InlineProtocolError.invalidInput }
    let padded = [UInt8](repeating: 0, count: 256 - value.count) + value
    var margin = [UInt8](repeating: 0, count: 256)
    margin[7] = 1
    let upper = subtractBigEndian(prime, margin)
    guard !lexicographicallyLess(padded, margin), !lexicographicallyLess(upper, padded)
    else { throw InlineProtocolError.invalidInput }
  }

  public static func encodeInlineInvoke(
    payload: [UInt8],
    layer: Int32 = realtimeLayer
  ) throws -> [UInt8] {
    try littleEndian(invokeConstructor) + littleEndian(layer) + encodeTLBytes(payload)
  }

  public static func encodeInlineResult(payload: [UInt8]) throws -> [UInt8] {
    try littleEndian(resultConstructor) + encodeTLBytes(payload)
  }

  public static func encodeInlineUpdate(payload: [UInt8]) throws -> [UInt8] {
    try littleEndian(updateConstructor) + encodeTLBytes(payload)
  }

  public static func decodeInlineApplicationObject(_ bytes: [UInt8]) throws -> InlineApplicationObject {
    guard bytes.count >= 8 else { throw InlineProtocolError.invalidInput }
    let constructor = try readUInt32(bytes, at: 0)
    if constructor == invokeConstructor {
      let layer = try readInt32(bytes, at: 4)
      let decoded = try decodeTLBytes(Array(bytes[8...]))
      guard decoded.consumed == bytes.count - 8 else { throw InlineProtocolError.invalidInput }
      return .invoke(layer: layer, payload: decoded.value)
    }
    let decoded = try decodeTLBytes(Array(bytes[4...]))
    guard decoded.consumed == bytes.count - 4 else { throw InlineProtocolError.invalidInput }
    switch constructor {
    case resultConstructor: return .result(payload: decoded.value)
    case updateConstructor: return .update(payload: decoded.value)
    default: throw InlineProtocolError.invalidInput
    }
  }

  public static func encodeInvokeAfterMessage(messageID: Int64, query: [UInt8]) throws -> [UInt8] {
    try validateTLQuery(query)
    return littleEndian(invokeAfterMessageConstructor) + littleEndian(messageID) + query
  }

  public static func encodeInvokeAfterMessages(messageIDs: [Int64], query: [UInt8]) throws -> [UInt8] {
    guard messageIDs.count <= maximumInvokeAfterDependencies else { throw InlineProtocolError.invalidInput }
    try validateTLQuery(query)
    return littleEndian(invokeAfterMessagesConstructor)
      + littleEndian(vectorConstructor)
      + littleEndian(Int32(messageIDs.count))
      + messageIDs.flatMap(littleEndian)
      + query
  }

  public static func decodeInvokeAfter(_ bytes: [UInt8]) throws -> InlineInvokeAfter {
    guard bytes.count >= 12,
          bytes.count <= maximumPacketBytes,
          bytes.count.isMultiple(of: 4)
    else { throw InlineProtocolError.invalidInput }
    let constructor = try readUInt32(bytes, at: 0)
    let messageIDs: [Int64]
    let queryOffset: Int
    switch constructor {
    case invokeAfterMessageConstructor:
      messageIDs = [try readInt64(bytes, at: 4)]
      queryOffset = 12
    case invokeAfterMessagesConstructor:
      guard try readUInt32(bytes, at: 4) == vectorConstructor else {
        throw InlineProtocolError.invalidInput
      }
      let count = Int(try readInt32(bytes, at: 8))
      guard (0...maximumInvokeAfterDependencies).contains(count),
            count <= (bytes.count - 12) / 8
      else { throw InlineProtocolError.invalidInput }
      messageIDs = try (0..<count).map { try readInt64(bytes, at: 12 + $0 * 8) }
      queryOffset = 12 + count * 8
    default:
      throw InlineProtocolError.invalidInput
    }
    let query = Array(bytes[queryOffset...])
    try validateTLQuery(query)
    return InlineInvokeAfter(messageIDs: messageIDs, query: query)
  }

  private static func validateTLQuery(_ query: [UInt8]) throws {
    guard query.count >= 4,
          query.count <= maximumPacketBytes,
          query.count.isMultiple(of: 4)
    else { throw InlineProtocolError.invalidInput }
  }

  public static func authKeyID(_ authKey: [UInt8]) throws -> [UInt8] {
    guard authKey.count == 256 else { throw InlineProtocolError.invalidInput }
    return sha1(authKey)[12..<20].map(\.self)
  }

  public static func computeV2MessageKey(
    authKey: [UInt8],
    plaintext: [UInt8],
    direction: InlineProtocolDirection
  ) throws -> [UInt8] {
    guard authKey.count == 256 else { throw InlineProtocolError.invalidInput }
    let x = direction.kdfOffset
    return sha256(Array(authKey[(88 + x)..<(120 + x)]) + plaintext)[8..<24].map(\.self)
  }

  public static func computeV2QuickAckID(
    authKey: [UInt8],
    plaintext: [UInt8],
    direction: InlineProtocolDirection
  ) throws -> UInt32 {
    guard authKey.count == 256 else { throw InlineProtocolError.invalidInput }
    let x = direction.kdfOffset
    let digest = sha256(Array(authKey[(88 + x)..<(120 + x)]) + plaintext)
    return (UInt32(digest[0])
      | UInt32(digest[1]) << 8
      | UInt32(digest[2]) << 16
      | UInt32(digest[3]) << 24) & 0x7fff_ffff
  }

  public static func deriveV2AES(
    authKey: [UInt8],
    messageKey: [UInt8],
    direction: InlineProtocolDirection
  ) throws -> (key: [UInt8], iv: [UInt8]) {
    guard authKey.count == 256, messageKey.count == 16 else { throw InlineProtocolError.invalidInput }
    let x = direction.kdfOffset
    let a = sha256(messageKey + authKey[x..<(36 + x)])
    let b = sha256(Array(authKey[(40 + x)..<(76 + x)]) + messageKey)
    return (
      Array(a[0..<8]) + Array(b[8..<24]) + Array(a[24..<32]),
      Array(b[0..<8]) + Array(a[8..<24]) + Array(b[24..<32])
    )
  }

  public static func aesIGEEncrypt(
    _ plaintext: [UInt8],
    key: [UInt8],
    iv: [UInt8]
  ) throws -> [UInt8] {
    try aesIGE(plaintext, key: key, iv: iv, operation: CCOperation(kCCEncrypt))
  }

  public static func aesIGEDecrypt(
    _ ciphertext: [UInt8],
    key: [UInt8],
    iv: [UInt8]
  ) throws -> [UInt8] {
    try aesIGE(ciphertext, key: key, iv: iv, operation: CCOperation(kCCDecrypt))
  }

  public static func encryptRecord(
    authKey: [UInt8],
    direction: InlineProtocolDirection,
    fields: InlineEncryptedRecordFields,
    padding: [UInt8]
  ) throws -> [UInt8] {
    guard fields.body.count <= maximumPacketBytes,
          fields.body.count.isMultiple(of: 4),
          (12...1024).contains(padding.count)
    else { throw InlineProtocolError.invalidInput }
    let plaintext = littleEndian(fields.serverSalt)
      + littleEndian(fields.sessionID)
      + littleEndian(fields.messageID)
      + littleEndian(fields.sequenceNumber)
      + littleEndian(Int32(fields.body.count))
      + fields.body
      + padding
    guard plaintext.count.isMultiple(of: 16) else { throw InlineProtocolError.invalidInput }
    let messageKey = try computeV2MessageKey(authKey: authKey, plaintext: plaintext, direction: direction)
    let aes = try deriveV2AES(authKey: authKey, messageKey: messageKey, direction: direction)
    return try authKeyID(authKey) + messageKey + aesIGEEncrypt(plaintext, key: aes.key, iv: aes.iv)
  }

  public static func decryptRecord(
    _ record: [UInt8],
    authKey: [UInt8],
    direction: InlineProtocolDirection,
    expectedSessionID: Int64,
    validServerSalts: Set<Int64>,
    nowSeconds: Int64
  ) throws -> InlineEncryptedRecordFields {
    do {
      guard record.count >= 72,
            record.count <= maximumPacketBytes,
            (record.count - 24).isMultiple(of: 16)
      else { throw InlineProtocolError.invalidEncryptedRecord }
      let messageKey = Array(record[8..<24])
      let aes = try deriveV2AES(authKey: authKey, messageKey: messageKey, direction: direction)
      let plaintext = try aesIGEDecrypt(Array(record[24...]), key: aes.key, iv: aes.iv)
      let expectedMessageKey = try computeV2MessageKey(authKey: authKey, plaintext: plaintext, direction: direction)
      let validKeyID = constantTimeEqual(Array(record[0..<8]), try authKeyID(authKey))
      let validMessageKey = constantTimeEqual(messageKey, expectedMessageKey)
      guard validKeyID, validMessageKey else { throw InlineProtocolError.invalidEncryptedRecord }

      let bodyLength = Int(try readInt32(plaintext, at: 28))
      guard bodyLength >= 0,
            bodyLength <= maximumPacketBytes,
            bodyLength.isMultiple(of: 4),
            plaintext.count >= 32 + bodyLength
      else { throw InlineProtocolError.invalidEncryptedRecord }
      let paddingLength = plaintext.count - 32 - bodyLength
      guard (12...1024).contains(paddingLength) else { throw InlineProtocolError.invalidEncryptedRecord }
      let serverSalt = try readInt64(plaintext, at: 0)
      let sessionID = try readInt64(plaintext, at: 8)
      let messageID = try readInt64(plaintext, at: 16)
      let sequenceNumber = try readInt32(plaintext, at: 24)
      let validDirection: Bool
      switch direction {
      case .clientToServer:
        validDirection = messageID & 3 == 0 && UInt32(truncatingIfNeeded: messageID) != 0
      case .serverToClient:
        validDirection = messageID & 1 == 1
      }
      let messageSeconds = messageID >> 32
      guard sessionID == expectedSessionID,
            validServerSalts.contains(serverSalt),
            messageID != 0,
            validDirection,
            (nowSeconds - 300...nowSeconds + 30).contains(messageSeconds),
            sequenceNumber >= 0
      else { throw InlineProtocolError.invalidEncryptedRecord }
      return InlineEncryptedRecordFields(
        serverSalt: serverSalt,
        sessionID: sessionID,
        messageID: messageID,
        sequenceNumber: sequenceNumber,
        body: Array(plaintext[32..<(32 + bodyLength)])
      )
    } catch {
      throw InlineProtocolError.invalidEncryptedRecord
    }
  }

  public static func encodeAbridgedPacket(
    _ payload: [UInt8],
    requestQuickAck: Bool = false
  ) throws -> [UInt8] {
    guard !payload.isEmpty,
          payload.count <= maximumPacketBytes,
          payload.count.isMultiple(of: 4)
    else { throw InlineProtocolError.invalidInput }
    let words = payload.count / 4
    let quickAckBit: UInt8 = requestQuickAck ? 0x80 : 0
    if words < 127 { return [UInt8(words) | quickAckBit] + payload }
    guard words <= 0x00ff_ffff else { throw InlineProtocolError.invalidInput }
    return [0x7f | quickAckBit, UInt8(words & 0xff), UInt8((words >> 8) & 0xff), UInt8((words >> 16) & 0xff)] + payload
  }

  public static func encodeAbridgedQuickAck(_ id: UInt32) throws -> [UInt8] {
    guard id <= 0x7fff_ffff else { throw InlineProtocolError.invalidInput }
    let value = id | 0x8000_0000
    return [
      UInt8((value >> 24) & 0xff),
      UInt8((value >> 16) & 0xff),
      UInt8((value >> 8) & 0xff),
      UInt8(value & 0xff),
    ]
  }

  public static func decodeAbridgedFrame(_ frame: [UInt8]) throws -> InlineAbridgedFrame {
    if frame.count == 4, frame[0] & 0x80 != 0 {
      let value = UInt32(frame[0]) << 24
        | UInt32(frame[1]) << 16
        | UInt32(frame[2]) << 8
        | UInt32(frame[3])
      return .quickAck(id: value & 0x7fff_ffff)
    }
    guard frame.count >= 2 else { throw InlineProtocolError.invalidInput }
    let marker = frame[0]
    let quickAckRequested = marker & 0x80 != 0
    let lengthMarker = marker & 0x7f
    let headerLength: Int
    let words: Int
    if lengthMarker == 0x7f {
      guard frame.count >= 4 else { throw InlineProtocolError.invalidInput }
      headerLength = 4
      words = Int(frame[1]) | Int(frame[2]) << 8 | Int(frame[3]) << 16
    } else {
      headerLength = 1
      words = Int(lengthMarker)
    }
    let (length, overflow) = words.multipliedReportingOverflow(by: 4)
    guard !overflow,
          words > 0,
          length <= maximumPacketBytes,
          frame.count == headerLength + length
    else { throw InlineProtocolError.invalidInput }
    return .packet(payload: Array(frame[headerLength...]), quickAckRequested: quickAckRequested)
  }

  private static func aesIGE(
    _ input: [UInt8],
    key: [UInt8],
    iv: [UInt8],
    operation: CCOperation
  ) throws -> [UInt8] {
    guard key.count == kCCKeySizeAES256, iv.count == 32, input.count.isMultiple(of: kCCBlockSizeAES128)
    else { throw InlineProtocolError.invalidInput }
    var previousCipher = Array(iv[0..<16])
    var previousPlain = Array(iv[16..<32])
    var output: [UInt8] = []
    output.reserveCapacity(input.count)
    for offset in stride(from: 0, to: input.count, by: 16) {
      let block = Array(input[offset..<(offset + 16)])
      if operation == CCOperation(kCCEncrypt) {
        let encrypted = try aesECB(xor(block, previousCipher), key: key, operation: operation)
        let result = xor(encrypted, previousPlain)
        output += result
        previousCipher = result
        previousPlain = block
      } else {
        let decrypted = try aesECB(xor(block, previousPlain), key: key, operation: operation)
        let result = xor(decrypted, previousCipher)
        output += result
        previousCipher = block
        previousPlain = result
      }
    }
    return output
  }

  private static func aesECB(_ input: [UInt8], key: [UInt8], operation: CCOperation) throws -> [UInt8] {
    var output = [UInt8](repeating: 0, count: input.count)
    let outputCapacity = output.count
    var moved = 0
    let status = key.withUnsafeBytes { keyBytes in
      input.withUnsafeBytes { inputBytes in
        output.withUnsafeMutableBytes { outputBytes in
          CCCrypt(
            operation,
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),
            keyBytes.baseAddress,
            key.count,
            nil,
            inputBytes.baseAddress,
            input.count,
            outputBytes.baseAddress,
            outputCapacity,
            &moved
          )
        }
      }
    }
    guard status == kCCSuccess, moved == input.count else { throw InlineProtocolError.invalidInput }
    return output
  }

  private static func sha1(_ input: [UInt8]) -> [UInt8] {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    input.withUnsafeBytes { bytes in
      _ = CC_SHA1(bytes.baseAddress, CC_LONG(input.count), &digest)
    }
    return digest
  }

  private static func sha256<S: Sequence>(_ input: S) -> [UInt8] where S.Element == UInt8 {
    let bytes = Array(input)
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    bytes.withUnsafeBytes { raw in
      _ = CC_SHA256(raw.baseAddress, CC_LONG(bytes.count), &digest)
    }
    return digest
  }

  private static func rsaPublicKey(modulus: [UInt8], exponent: [UInt8]) throws -> SecKey {
    let body = asn1Integer(modulus) + asn1Integer(exponent)
    let der = [UInt8(0x30)] + asn1Length(body.count) + body
    let attributes: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass: kSecAttrKeyClassPublic,
      kSecAttrKeySizeInBits: 2048,
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, &error) else {
      if let error { throw error.takeRetainedValue() }
      throw InlineProtocolError.invalidInput
    }
    return key
  }

  private static func asn1Integer(_ bytes: [UInt8]) -> [UInt8] {
    let trimmed = Array(bytes.drop(while: { $0 == 0 }))
    let unsigned = (trimmed.first ?? 0) & 0x80 == 0 ? trimmed : [0] + trimmed
    return [0x02] + asn1Length(unsigned.count) + unsigned
  }

  private static func hexBytes(_ value: String) -> [UInt8] {
    stride(from: 0, to: value.count, by: 2).map { offset in
      let start = value.index(value.startIndex, offsetBy: offset)
      let end = value.index(start, offsetBy: 2)
      return UInt8(value[start..<end], radix: 16)!
    }
  }

  private static func asn1Length(_ length: Int) -> [UInt8] {
    if length < 128 { return [UInt8(length)] }
    var value = length
    var bytes: [UInt8] = []
    while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
    return [0x80 | UInt8(bytes.count)] + bytes
  }

  private static func lexicographicallyLess(_ left: [UInt8], _ right: [UInt8]) -> Bool {
    for pair in zip(left, right) where pair.0 != pair.1 { return pair.0 < pair.1 }
    return left.count < right.count
  }

  private static func subtractBigEndian(_ left: [UInt8], _ right: [UInt8]) -> [UInt8] {
    var output = left
    var borrow = 0
    for index in stride(from: left.count - 1, through: 0, by: -1) {
      let difference = Int(left[index]) - Int(right[index]) - borrow
      output[index] = UInt8(truncatingIfNeeded: difference)
      borrow = difference < 0 ? 1 : 0
    }
    return output
  }

  private static func constantTimeEqual(_ left: [UInt8], _ right: [UInt8]) -> Bool {
    var difference = left.count ^ right.count
    for index in 0..<max(left.count, right.count) {
      difference |= Int((index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0))
    }
    return difference == 0
  }

  private static func xor(_ left: [UInt8], _ right: [UInt8]) -> [UInt8] {
    zip(left, right).map(^)
  }

  private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian, Array.init)
  }

  private static func encodeTLBytes(_ value: [UInt8]) throws -> [UInt8] {
    guard value.count <= maximumPacketBytes, value.count <= 0x00ff_ffff else {
      throw InlineProtocolError.invalidInput
    }
    var output: [UInt8]
    if value.count < 254 {
      output = [UInt8(value.count)] + value
    } else {
      output = [254, UInt8(value.count & 0xff), UInt8((value.count >> 8) & 0xff), UInt8((value.count >> 16) & 0xff)] + value
    }
    output += repeatElement(0, count: (4 - output.count % 4) % 4)
    return output
  }

  private static func decodeTLBytes(_ bytes: [UInt8]) throws -> (value: [UInt8], consumed: Int) {
    guard let first = bytes.first else { throw InlineProtocolError.invalidInput }
    let headerLength: Int
    let length: Int
    if first < 254 {
      headerLength = 1
      length = Int(first)
    } else if first == 254, bytes.count >= 4 {
      headerLength = 4
      length = Int(bytes[1]) | Int(bytes[2]) << 8 | Int(bytes[3]) << 16
    } else {
      throw InlineProtocolError.invalidInput
    }
    let encodedLength = headerLength + length
    let totalLength = encodedLength + (4 - encodedLength % 4) % 4
    guard length <= maximumPacketBytes,
          bytes.count >= totalLength,
          bytes[encodedLength..<totalLength].allSatisfy({ $0 == 0 })
    else { throw InlineProtocolError.invalidInput }
    return (Array(bytes[headerLength..<(headerLength + length)]), totalLength)
  }

  private static func readInt32(_ bytes: [UInt8], at offset: Int) throws -> Int32 {
    guard offset >= 0, offset + 4 <= bytes.count else { throw InlineProtocolError.invalidInput }
    let raw = bytes[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { result, pair in
      result | UInt32(pair.element) << UInt32(pair.offset * 8)
    }
    return Int32(bitPattern: raw)
  }

  private static func readUInt32(_ bytes: [UInt8], at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset + 4 <= bytes.count else { throw InlineProtocolError.invalidInput }
    return bytes[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { result, pair in
      result | UInt32(pair.element) << UInt32(pair.offset * 8)
    }
  }

  private static func readInt64(_ bytes: [UInt8], at offset: Int) throws -> Int64 {
    guard offset >= 0, offset + 8 <= bytes.count else { throw InlineProtocolError.invalidInput }
    let raw = bytes[offset..<(offset + 8)].enumerated().reduce(UInt64(0)) { result, pair in
      result | UInt64(pair.element) << UInt64(pair.offset * 8)
    }
    return Int64(bitPattern: raw)
  }
}

public struct InlineReceiveMessageWindow: Sendable {
  private let capacity: Int
  private var accepted: Set<Int64> = []

  public init(capacity: Int = 1000) {
    precondition(capacity > 0)
    self.capacity = capacity
  }

  public mutating func claim(_ messageID: Int64) -> Bool {
    guard !accepted.contains(messageID) else { return false }
    if accepted.count >= capacity, let minimum = accepted.min(), messageID < minimum { return false }
    accepted.insert(messageID)
    while accepted.count > capacity, let minimum = accepted.min() { accepted.remove(minimum) }
    return true
  }
}
