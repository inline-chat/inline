import CommonCrypto
import Foundation
import Testing
@testable import InlineProtocol

@Suite("Inline Protocol transfer performance primitives")
struct TransferPerformanceTests {
  @Test("one-cryptor IGE matches the per-block reference for random sizes")
  func igeMatchesReference() throws {
    for blocks in [1, 2, 3, 17, 64, 255, 1_024] {
      let input = randomBytes(blocks * 16)
      let key = randomBytes(32)
      let iv = randomBytes(32)
      let encrypted = try InlineSecureTransport.aesIGEEncrypt(input, key: key, iv: iv)
      #expect(encrypted == aesIGEReference(input, key: key, iv: iv, encrypt: true))
      let decrypted = try InlineSecureTransport.aesIGEDecrypt(encrypted, key: key, iv: iv)
      #expect(decrypted == input)
      #expect(decrypted == aesIGEReference(encrypted, key: key, iv: iv, encrypt: false))
    }
    #expect(throws: InlineProtocolError.invalidInput) {
      try InlineSecureTransport.aesIGEEncrypt(randomBytes(15), key: randomBytes(32), iv: randomBytes(32))
    }
  }

  @Test("encrypts and decrypts a 512 KiB record body within a loose budget")
  func igeBudget() throws {
    let input = randomBytes(512 * 1024)
    let key = randomBytes(32)
    let iv = randomBytes(32)
    let clock = ContinuousClock()
    let started = clock.now
    let encrypted = try InlineSecureTransport.aesIGEEncrypt(input, key: key, iv: iv)
    let decrypted = try InlineSecureTransport.aesIGEDecrypt(encrypted, key: key, iv: iv)
    let elapsed = clock.now - started
    #expect(decrypted == input)
    // Debug builds included; the per-block CCCrypt version took tens of milliseconds per direction.
    #expect(elapsed < .milliseconds(400))
  }

  @Test("decodes the shared gzip_packed rpc_result vector")
  func gzipPackedVector() throws {
    let root = try #require(JSONSerialization.jsonObject(with: InlineProtocolVectors.v1JSON()) as? [String: Any])
    let serviceObjects = try #require(root["serviceObjects"] as? [String: Any])
    let rpcResult = hexBytes(try #require(serviceObjects["gzipPackedRpcResultHex"] as? String))
    let inner = hexBytes(try #require(serviceObjects["gzipPackedInnerResultHex"] as? String))
    #expect(Array(rpcResult[0 ..< 4]) == [0x01, 0x6d, 0x5c, 0xf3])
    let result = Array(rpcResult.dropFirst(12))
    #expect(try InlineSecureTransport.unpackGzip(result) == inner)
    guard case let .result(payload) = try InlineSecureTransport.decodeInlineApplicationObject(inner) else {
      Issue.record("expected an Inline result")
      return
    }
    #expect(payload.count == 2_048)
    // Bodies that are not gzip_packed pass through unchanged.
    #expect(try InlineSecureTransport.unpackGzip(inner) == inner)
  }

  @Test("rejects corrupt, oversized and truncated gzip streams")
  func gzipRejections() throws {
    let root = try #require(JSONSerialization.jsonObject(with: InlineProtocolVectors.v1JSON()) as? [String: Any])
    let serviceObjects = try #require(root["serviceObjects"] as? [String: Any])
    let packedBody = Array(hexBytes(try #require(serviceObjects["gzipPackedRpcResultHex"] as? String)).dropFirst(12))
    let stream = try tlBytes(Array(packedBody.dropFirst(4)))
    #expect(try InlineSecureTransport.gunzip(stream, maximumOutputBytes: 1 << 20).count > 0)

    var corruptCRC = stream
    corruptCRC[corruptCRC.count - 8] ^= 0xff
    #expect(throws: InlineProtocolError.invalidInput) {
      try InlineSecureTransport.gunzip(corruptCRC, maximumOutputBytes: 1 << 20)
    }
    #expect(throws: InlineProtocolError.invalidInput) {
      try InlineSecureTransport.gunzip(stream, maximumOutputBytes: 100)
    }
    var understated = stream
    understated[understated.count - 4] = 1
    understated[understated.count - 3] = 0
    understated[understated.count - 2] = 0
    understated[understated.count - 1] = 0
    #expect(throws: InlineProtocolError.invalidInput) {
      try InlineSecureTransport.gunzip(understated, maximumOutputBytes: 1 << 20)
    }
    #expect(throws: InlineProtocolError.invalidInput) {
      try InlineSecureTransport.gunzip(Array(stream.prefix(20)), maximumOutputBytes: 1 << 20)
    }
  }

  @Test("encodes the shared message container vector")
  func containerVector() throws {
    let root = try #require(JSONSerialization.jsonObject(with: InlineProtocolVectors.v1JSON()) as? [String: Any])
    let serviceObjects = try #require(root["serviceObjects"] as? [String: Any])
    let applicationObjects = try #require(root["applicationObjects"] as? [String: Any])
    let invoke = hexBytes(try #require(applicationObjects["invokeHex"] as? String))
    let acknowledgement: [UInt8] = [0x59, 0xb4, 0xd6, 0x62, 0x15, 0xc4, 0xb5, 0x1c, 1, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0]
    let container = try InlineSecureTransport.encodeMessageContainer([
      (messageID: 4, sequenceNumber: 1, body: invoke),
      (messageID: 8, sequenceNumber: 0, body: acknowledgement),
    ])
    #expect(container.map { String(format: "%02x", $0) }.joined() == serviceObjects["containerHex"] as? String)
    #expect(throws: InlineProtocolError.invalidInput) {
      try InlineSecureTransport.encodeMessageContainer([(messageID: 4, sequenceNumber: 0, body: container)])
    }
  }

  @Test("layer-4 invokes keep the layer-3 request encoding")
  func gzipLayerInvoke() throws {
    let payload: [UInt8] = [8, 1]
    let layer3 = try InlineSecureTransport.encodeInlineInvoke(payload: payload)
    let layer4 = try InlineSecureTransport.encodeInlineInvoke(payload: payload, layer: InlineSecureTransport.realtimeLayerGzip)
    #expect(Array(layer3[0 ..< 4]) == Array(layer4[0 ..< 4]))
    #expect(layer4[4] == 4)
    #expect(Array(layer3[8...]) == Array(layer4[8...]))
  }
}

/// The previous implementation, one `CCCrypt` (and key schedule) per block, kept as a reference.
private func aesIGEReference(_ input: [UInt8], key: [UInt8], iv: [UInt8], encrypt: Bool) -> [UInt8] {
  var previousCipher = Array(iv[0 ..< 16])
  var previousPlain = Array(iv[16 ..< 32])
  var output: [UInt8] = []
  for offset in stride(from: 0, to: input.count, by: 16) {
    let block = Array(input[offset ..< offset + 16])
    if encrypt {
      let result = xor(ecb(xor(block, previousCipher), key: key, encrypt: true), previousPlain)
      output += result
      previousCipher = result
      previousPlain = block
    } else {
      let result = xor(ecb(xor(block, previousPlain), key: key, encrypt: false), previousCipher)
      output += result
      previousCipher = block
      previousPlain = result
    }
  }
  return output
}

private func ecb(_ input: [UInt8], key: [UInt8], encrypt: Bool) -> [UInt8] {
  var output = [UInt8](repeating: 0, count: 16)
  var moved = 0
  _ = CCCrypt(
    CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
    key, key.count, nil, input, input.count, &output, output.count, &moved
  )
  return output
}

private func xor(_ left: [UInt8], _ right: [UInt8]) -> [UInt8] {
  zip(left, right).map { $0 ^ $1 }
}

private func randomBytes(_ count: Int) -> [UInt8] {
  (0 ..< count).map { _ in UInt8.random(in: 0 ... 255) }
}

private func hexBytes(_ hex: String) -> [UInt8] {
  stride(from: 0, to: hex.count, by: 2).map { offset in
    let start = hex.index(hex.startIndex, offsetBy: offset)
    return UInt8(hex[start ..< hex.index(start, offsetBy: 2)], radix: 16)!
  }
}

/// Decodes a TL `bytes` value (the gzip stream inside gzip_packed).
private func tlBytes(_ bytes: [UInt8]) throws -> [UInt8] {
  if bytes[0] < 254 { return Array(bytes[1 ..< 1 + Int(bytes[0])]) }
  let length = Int(bytes[1]) | Int(bytes[2]) << 8 | Int(bytes[3]) << 16
  return Array(bytes[4 ..< 4 + length])
}
