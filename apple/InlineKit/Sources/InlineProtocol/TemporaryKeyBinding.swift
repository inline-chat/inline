import CommonCrypto
import Foundation
import Security

public enum InlineTemporaryKeyBinding {
  private static let innerConstructor: UInt32 = 0x75a3f765
  private static let outerConstructor: UInt32 = 0xcdd42a05

  public static func createProof(
    permanent: InlineProtocolAuthorization,
    temporary: InlineProtocolAuthorization,
    temporarySessionID: Int64,
    messageID: Int64,
    nonce: Int64,
    expiresAt: Int32,
    randomInt128: [UInt8],
    randomPadding: [UInt8]
  ) throws -> [UInt8] {
    guard randomInt128.count == 16, randomPadding.count == 8,
          permanent.key.count == 256, temporary.key.count == 256
    else { throw InlineProtocolError.invalidInput }
    let inner = littleBinding(innerConstructor) + littleBinding(nonce)
      + littleBinding(readBindingInt64(temporary.keyID))
      + littleBinding(readBindingInt64(permanent.keyID))
      + littleBinding(temporarySessionID) + littleBinding(expiresAt)
    let plaintext = randomInt128 + littleBinding(messageID) + littleBinding(Int32(0))
      + littleBinding(Int32(inner.count)) + inner
    let messageKey = Array(bindingSHA1(plaintext)[4..<20])
    let aes = try deriveV1AES(authKey: permanent.key, messageKey: messageKey)
    return permanent.keyID + messageKey
      + (try InlineSecureTransport.aesIGEEncrypt(plaintext + randomPadding, key: aes.key, iv: aes.iv))
  }

  public static func encodeRequest(
    permanentKeyID: Int64,
    nonce: Int64,
    expiresAt: Int32,
    proof: [UInt8]
  ) throws -> [UInt8] {
    guard proof.count == 104 else { throw InlineProtocolError.invalidInput }
    return littleBinding(outerConstructor) + littleBinding(permanentKeyID) + littleBinding(nonce)
      + littleBinding(expiresAt) + (try encodeBindingTLBytes(proof))
  }

  private static func deriveV1AES(
    authKey: [UInt8],
    messageKey: [UInt8]
  ) throws -> (key: [UInt8], iv: [UInt8]) {
    guard authKey.count == 256, messageKey.count == 16 else { throw InlineProtocolError.invalidInput }
    let a = bindingSHA1(messageKey + Array(authKey[0..<32]))
    let b = bindingSHA1(Array(authKey[32..<48]) + messageKey + Array(authKey[48..<64]))
    let c = bindingSHA1(Array(authKey[64..<96]) + messageKey)
    let d = bindingSHA1(messageKey + Array(authKey[96..<128]))
    return (
      Array(a[0..<8]) + Array(b[8..<20]) + Array(c[4..<16]),
      Array(a[8..<20]) + Array(b[0..<8]) + Array(c[16..<20]) + Array(d[0..<8])
    )
  }
}

private func bindingSHA1(_ value: [UInt8]) -> [UInt8] {
  var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
  value.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(value.count), &digest) }
  return digest
}

private func littleBinding<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  withUnsafeBytes(of: value.littleEndian, Array.init)
}

private func readBindingInt64(_ value: [UInt8]) -> Int64 {
  Int64(bitPattern: value.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64($1.offset * 8) })
}

private func encodeBindingTLBytes(_ value: [UInt8]) throws -> [UInt8] {
  guard value.count <= 0x00ff_ffff else { throw InlineProtocolError.invalidInput }
  var output = value.count < 254
    ? [UInt8(value.count)] + value
    : [254, UInt8(value.count), UInt8(value.count >> 8), UInt8(value.count >> 16)] + value
  output += repeatElement(0, count: (4 - output.count % 4) % 4)
  return output
}
