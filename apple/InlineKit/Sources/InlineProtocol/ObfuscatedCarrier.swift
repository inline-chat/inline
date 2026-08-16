import CommonCrypto
import Foundation

public final class InlineAESCTRStream: @unchecked Sendable {
  private let lock = NSLock()
  private let cryptor: CCCryptorRef

  public init(key: [UInt8], iv: [UInt8]) throws {
    guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else {
      throw InlineProtocolError.invalidInput
    }
    var created: CCCryptorRef?
    let status = key.withUnsafeBytes { keyBytes in
      iv.withUnsafeBytes { ivBytes in
        CCCryptorCreateWithMode(
          CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
          CCPadding(ccNoPadding), ivBytes.baseAddress, keyBytes.baseAddress, key.count,
          nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &created
        )
      }
    }
    guard status == kCCSuccess, let created else { throw InlineProtocolError.invalidInput }
    cryptor = created
  }

  deinit {
    CCCryptorRelease(cryptor)
  }

  public func process(_ input: [UInt8]) throws -> [UInt8] {
    try lock.withLock {
      var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
      let outputCapacity = output.count
      var moved = 0
      let status = input.withUnsafeBytes { inputBytes in
        output.withUnsafeMutableBytes { outputBytes in
          CCCryptorUpdate(
            cryptor, inputBytes.baseAddress, input.count,
            outputBytes.baseAddress, outputCapacity, &moved
          )
        }
      }
      guard status == kCCSuccess, moved == input.count else { throw InlineProtocolError.invalidInput }
      return Array(output.prefix(moved))
    }
  }
}

public struct InlineObfuscatedClientCarrier: Sendable {
  public let wireHeader: [UInt8]
  public let outbound: InlineAESCTRStream
  public let inbound: InlineAESCTRStream

  public init(randomHeader: [UInt8], dc: Int16 = 1) throws {
    guard Self.isValidHeader(randomHeader) else { throw InlineProtocolError.invalidInput }
    var plaintext = randomHeader
    plaintext.replaceSubrange(56..<60, with: repeatElement(UInt8(0xef), count: 4))
    plaintext.replaceSubrange(60..<62, with: withUnsafeBytes(of: dc.littleEndian, Array.init))
    let reversed = Array(plaintext.reversed())
    let outbound = try InlineAESCTRStream(key: Array(plaintext[8..<40]), iv: Array(plaintext[40..<56]))
    let inbound = try InlineAESCTRStream(key: Array(reversed[8..<40]), iv: Array(reversed[40..<56]))
    let encrypted = try outbound.process(plaintext)
    self.wireHeader = Array(plaintext[0..<56]) + Array(encrypted[56..<64])
    self.outbound = outbound
    self.inbound = inbound
  }

  public static func isValidHeader(_ header: [UInt8]) -> Bool {
    guard header.count == 64, header[0] != 0xef else { return false }
    let first = readUInt32(header, at: 0)
    let second = readUInt32(header, at: 4)
    return !forbiddenPrefixes.contains(first) && second != 0
  }

  private static let forbiddenPrefixes: Set<UInt32> = [
    0x44414548, 0x54534f50, 0x20544547, 0x4954504f,
    0xeeeeeeee, 0xdddddddd, 0x02010316,
  ]

  private static func readUInt32(_ value: [UInt8], at offset: Int) -> UInt32 {
    value[offset..<(offset + 4)].enumerated().reduce(0) {
      $0 | UInt32($1.element) << UInt32($1.offset * 8)
    }
  }
}
