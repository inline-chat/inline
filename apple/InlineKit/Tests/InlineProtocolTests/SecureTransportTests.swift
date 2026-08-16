import CryptoKit
import Foundation
import Testing
@testable import InlineProtocol

@Suite("Inline Protocol portable core")
struct SecureTransportTests {
  @Test("loads the exact shared language-neutral corpus")
  func sharedVectorCorpus() throws {
    let data = try InlineProtocolVectors.v1JSON()
    #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      == "73fbe70763140f91cd1667c9d714848acfe0234a770ee2dfb891939ac2148893")
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["formatVersion"] as? Int == 1)
    #expect(object["protocol"] as? String == "Inline Protocol v1")
    let transcripts = try #require(object["handshakeTranscripts"] as? [String: Any])
    let permanent = try #require(transcripts["permanent"] as? [String: Any])
    let temporary = try #require(transcripts["temporary"] as? [String: Any])
    #expect((permanent["requestHex"] as? [String])?.count == 3)
    #expect((permanent["authKeyHex"] as? String)?.count == 512)
    #expect(temporary["expiresAt"] as? Int == 1_700_086_400)
  }

  @Test("matches the frozen TypeScript and Rust record vector")
  func frozenRecordVector() throws {
    let authKey = Array(UInt8.min...UInt8.max)
    let fields = InlineEncryptedRecordFields(
      serverSalt: 0x0102030405060708,
      sessionID: 0x1112131415161718,
      messageID: (1_700_000_000 << 32) | 4,
      sequenceNumber: 1,
      body: [0xa6, 0x4a, 0x7d, 0xeb, 3, 0, 0, 0]
    )
    let padding = Array(UInt8(0xa0)...UInt8(0xb7))
    let record = try InlineSecureTransport.encryptRecord(
      authKey: authKey,
      direction: .clientToServer,
      fields: fields,
      padding: padding
    )
    #expect(record.hex == "32d1586ea457dfc80b016bab73824ee1e75f00f0fa824908302fa5dab375c8029b169848525548f61add2955845b9810fe817fcc7581efd11aaac110560a2cc78ae6a20cc6216a0b86fa0d061a57f84bacbf84af84ec31b4")
    let plaintext = withUnsafeBytes(of: fields.serverSalt.littleEndian, Array.init)
      + withUnsafeBytes(of: fields.sessionID.littleEndian, Array.init)
      + withUnsafeBytes(of: fields.messageID.littleEndian, Array.init)
      + withUnsafeBytes(of: fields.sequenceNumber.littleEndian, Array.init)
      + withUnsafeBytes(of: Int32(fields.body.count).littleEndian, Array.init)
      + fields.body
      + padding
    #expect(try InlineSecureTransport.computeV2QuickAckID(
      authKey: authKey,
      plaintext: plaintext,
      direction: .clientToServer
    ) == 140_616_213)
    #expect(try InlineSecureTransport.decryptRecord(
      record,
      authKey: authKey,
      direction: .clientToServer,
      expectedSessionID: fields.sessionID,
      validServerSalts: [fields.serverSalt],
      nowSeconds: 1_700_000_000
    ) == fields)
    var tampered = record
    tampered[40] ^= 1
    #expect(throws: (any Error).self) {
      try InlineSecureTransport.decryptRecord(
        tampered,
        authKey: authKey,
        direction: .clientToServer,
        expectedSessionID: fields.sessionID,
        validServerSalts: [fields.serverSalt],
        nowSeconds: 1_700_000_000
      )
    }
  }

  @Test("matches Telegram abridged quick-ACK framing")
  func quickAckFraming() throws {
    let payload: [UInt8] = [1, 2, 3, 4]
    let packet = try InlineSecureTransport.encodeAbridgedPacket(payload, requestQuickAck: true)
    #expect(packet == [0x81, 1, 2, 3, 4])
    #expect(try InlineSecureTransport.decodeAbridgedFrame(packet) == .packet(
      payload: payload,
      quickAckRequested: true
    ))
    #expect(try InlineSecureTransport.encodeAbridgedQuickAck(0x1234_5678) == [0x92, 0x34, 0x56, 0x78])
    #expect(try InlineSecureTransport.decodeAbridgedFrame([0x92, 0x34, 0x56, 0x78]) == .quickAck(
      id: 0x1234_5678
    ))
    #expect(throws: (any Error).self) {
      try InlineSecureTransport.decodeAbridgedFrame([0x80, 0, 0, 0, 0])
    }
  }

  @Test("receive window permits fresh out-of-order IDs")
  func receiveWindow() {
    var window = InlineReceiveMessageWindow(capacity: 3)
    let results = [
      window.claim(8),
      window.claim(4),
      window.claim(12),
      window.claim(8),
      window.claim(16),
      window.claim(4),
    ]
    #expect(results == [true, true, true, false, true, false])
  }

  @Test("matches all three Inline application constructors")
  func applicationConstructors() throws {
    let payload: [UInt8] = [8, 150, 1]
    #expect(try InlineSecureTransport.encodeInlineInvoke(payload: payload).hex == "a64a7deb0300000003089601")
    #expect(try InlineSecureTransport.encodeInlineResult(payload: payload).hex == "54dc3dac03089601")
    #expect(try InlineSecureTransport.encodeInlineUpdate(payload: payload).hex == "982c41dc03089601")
    #expect(try InlineSecureTransport.decodeInlineApplicationObject(
      InlineSecureTransport.encodeInlineInvoke(payload: payload)
    ) == .invoke(layer: 3, payload: payload))
  }

  @Test("matches Telegram invoke-after constructors")
  func invokeAfterConstructors() throws {
    let query = try InlineSecureTransport.encodeInlineInvoke(payload: [1, 2, 3])
    let single = try InlineSecureTransport.encodeInvokeAfterMessage(messageID: 4, query: query)
    #expect(single.hex.hasPrefix("2d379fcb"))
    #expect(try InlineSecureTransport.decodeInvokeAfter(single) == InlineInvokeAfter(
      messageIDs: [4],
      query: query
    ))
    let multiple = try InlineSecureTransport.encodeInvokeAfterMessages(messageIDs: [4, 8], query: query)
    #expect(multiple.hex.hasPrefix("f0b4c43d"))
    #expect(try InlineSecureTransport.decodeInvokeAfter(multiple) == InlineInvokeAfter(
      messageIDs: [4, 8],
      query: query
    ))
  }

  @Test("matches the frozen RSA_PAD and temporary-DH vectors")
  func handshakeVectors() throws {
    let modulus = bytes("f0d6060f41eb501851051808d4900eb0d044accfe02afbfe3821b6afecf92ffb1c7c8bfbff72e60287f06fe71d03dbf8867c7bd17f7de8bceac32c68543ce43568d6d47c2fd348527a860260cb162c05a8563ca85a62adb9ef469c70449ca31a28b22ccf7e9189d9d75f2998d4f085b2730058fe485f1922ca84ee3913fe3fba65f2a9ca922f105f9c3af8ddca7b4fc039c581796511fc71af021923a889ba42c4bacdd2599d3e97ff00cb390bd09bce84ec14228058cfb9675876b9a1ddc7576a90e7b563d2e018deb0f2dde0282817521a24e8da2f28700856e8667b31c4f304169fc2d575b23b78b050063788e9b4b8b17a43d290e9afde6e3e4a52c94ed1")
    let rsa = try InlineSecureTransport.rsaPadAttempt(
      serializedInner: (0..<64).map(UInt8.init),
      randomPadding: Array(UInt8(0x80)...UInt8(0xff)),
      temporaryKey: Array(UInt8(0x20)..<UInt8(0x40)),
      modulus: modulus,
      exponent: [1, 0, 1]
    )
    #expect(rsa.encryptedData.hex == "05a08c73f3cd8e128b23dcdc75d247d723d35436f7716ca13b9b050bf0684bfd6b4915d8679e59f8c28a9ec4e161ad75b74bbdee9e5e480e3178b6edac3c10cc80cde9872cf1213be099e6d6bea74a8d231f36c569e5fba8818a4282191537946e6ad46526249bc4600f960868af9872e4463f7154ac56b00f38c2c028043314d016dda7e0b5b65ea3b211d509c39f17b18d3850a2629dfd1aa3ef129b1d5b8d26bc8b001e5f6134c3f3acefe5974a0072a488e8449ce61fbfc481739948bcead7594d23ffbbc2a9a9ebb168ee707a8567ad28d525cefab2aae6e0d4eb279fe1768a9e6277a53e18e996bc74846cb11ffeb981015a595980b420dc02d124eedd")

    let newNonce = (0..<32).map(UInt8.init)
    let serverNonce = Array(UInt8(0xf0)...UInt8(0xff))
    let temporary = try InlineSecureTransport.deriveTemporaryAES(newNonce: newNonce, serverNonce: serverNonce)
    #expect(temporary.key.hex == "5f243f0afc16828a28a81163dcf0e3c45e744029e5f224b6de5d8a708e3ead3b")
    #expect(temporary.iv.hex == "7ddc813131e5cbaae864070e166e6218f6783e8511471a5ab7802cf200010203")
    let serialized = Array(UInt8(0x40)..<UInt8(0x6b))
    let encrypted = try InlineSecureTransport.encryptDHInner(
      serialized: serialized,
      padding: [0xaa],
      newNonce: newNonce,
      serverNonce: serverNonce
    )
    #expect(encrypted.hex == "f4b876fcb58c64e1d91c8561498104ca5f7cba9c8dae72b335bd6544259c2d54a361efc08a3a19cd6078ac480135a38b73dfba32c4d424659c49f23871107bc4")
    #expect(try InlineSecureTransport.decryptDHInner(
      encrypted: encrypted,
      serializedLength: serialized.count,
      newNonce: newNonce,
      serverNonce: serverNonce
    ) == serialized)
  }

  @Test("matches the frozen cross-language permanent client handshake")
  func clientHandshakeTranscript() throws {
    let root = try #require(JSONSerialization.jsonObject(with: InlineProtocolVectors.v1JSON()) as? [String: Any])
    let transcripts = try #require(root["handshakeTranscripts"] as? [String: Any])
    let transcript = try #require(transcripts["permanent"] as? [String: Any])
    let calls = try #require(transcript["clientRandomCalls"] as? [[String: Any]])
    let random = DeterministicHandshakeRandom(calls: try calls.map {
      bytes(try #require($0["hex"] as? String))
    })
    let fingerprintString = try #require(transcript["rsaFingerprint"] as? String)
    let fingerprint = try #require(Int64(fingerprintString))
    let key = try InlineProtocolRSAPublicKey(
      modulus: bytes(try #require(transcript["rsaModulusHex"] as? String)),
      exponent: bytes(try #require(transcript["rsaExponentHex"] as? String)),
      fingerprint: fingerprint
    )
    let requests = try #require(transcript["requestHex"] as? [String])
    let responses = try #require(transcript["responseHex"] as? [String])
    let client = InlineHandshakeClient(rsaKeys: [key], randomBytes: random.bytes)
    #expect(try client.begin(temporary: false).hex == requests[0])
    for index in 0..<2 {
      let transition = try client.receive(bytes(responses[index]))
      guard case let .request(request) = transition else {
        Issue.record("handshake completed early")
        return
      }
      #expect(request.hex == requests[index + 1])
    }
    let transition = try client.receive(bytes(responses[2]))
    guard case let .established(authorization, _) = transition else {
      Issue.record("handshake did not complete")
      return
    }
    #expect(authorization.key.hex == transcript["authKeyHex"] as? String)
    #expect(authorization.keyID.hex == transcript["authKeyIdHex"] as? String)
    #expect(String(authorization.serverSalt) == transcript["serverSalt"] as? String)
    #expect(!authorization.temporary)
  }

  @Test("completes the opt-in local V3 login, bind, RPC, and reconnect flow")
  func localV3Integration() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let ringPath = environment["INLINE_V3_PUBLIC_RING"],
          let urlString = environment["INLINE_V3_URL"],
          let url = URL(string: urlString),
          let email = environment["DEMO_EMAIL"],
          let code = environment["DEMO_CODE"]
    else { return }
    let keys = try InlineProtocolTrustRoots.decodeRing(Data(contentsOf: URL(fileURLWithPath: ringPath)))
    let permanentConnection = try await InlineProtocolV3Connection.connect(.init(
      url: url,
      rsaPublicKeys: keys
    ))
    var begin = AuthBeginRequest()
    begin.identifier = .email(email)
    let challenge = try await permanentConnection.authBegin(begin)
    var complete = AuthCompleteRequest()
    complete.challengeID = challenge.challengeID
    complete.code = code
    let completed = try await permanentConnection.authComplete(complete)
    guard case let .authorized(authorized) = completed.state else {
      Issue.record("local V3 login was not authorized")
      return
    }
    let permanent = await permanentConnection.authorization

    let temporaryConnection = try await InlineProtocolV3Connection.connect(.init(
      url: url,
      rsaPublicKeys: keys,
      temporary: true
    ))
    try await temporaryConnection.bindTemporary(to: permanent)
    let temporary = await temporaryConnection.authorization
    let first = try await temporaryConnection.callRPC(getMeCall())
    guard case let .getMe(me) = first.result else {
      Issue.record("local V3 getMe returned an unexpected result")
      return
    }
    #expect(me.user.id == authorized.user.id)
    await temporaryConnection.close()
    await permanentConnection.close()

    let reconnected = try await InlineProtocolV3Connection.connect(.reconnect(
      url: url,
      authorization: temporary
    ))
    let second = try await reconnected.callRPC(getMeCall())
    guard case let .getMe(meAfterReconnect) = second.result else {
      Issue.record("local V3 reconnect getMe returned an unexpected result")
      return
    }
    #expect(meAfterReconnect.user.id == authorized.user.id)
    await reconnected.close()
  }

  #if !DEBUG
  @Test("accepts an unfamiliar Telegram-valid safe prime with all 64 rounds")
  func unfamiliarSafePrime() throws {
    // RFC 3526 group 14 is an independent 2048-bit safe prime with g = 2.
    let prime = bytes(
      "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74" +
        "020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f1437" +
        "4fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed" +
        "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf05" +
        "98da48361c55d39a69163fa8fd24cf5f83655d23dca3ad961c62f356208552bb" +
        "9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b" +
        "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf695581718" +
        "3995497cea956ae515d2261898fa051015728e5a8aacaa68ffffffffffffffff"
    )
    try InlineSecureTransport.validateDHParameters(primeBytes: prime, generator: 2)
    #expect(throws: (any Error).self) {
      try InlineSecureTransport.validateDHParameters(primeBytes: prime, generator: 8)
    }
  }
  #endif
}

private func getMeCall() -> RpcCall {
  var call = RpcCall()
  call.method = .getMe
  call.input = .getMe(GetMeInput())
  return call
}

private final class DeterministicHandshakeRandom: @unchecked Sendable {
  private let lock = NSLock()
  private var calls: [[UInt8]]

  init(calls: [[UInt8]]) {
    self.calls = calls
  }

  func bytes(count: Int) throws -> [UInt8] {
    try lock.withLock {
      guard !calls.isEmpty else { throw InlineProtocolError.invalidInput }
      let value = calls.removeFirst()
      guard value.count == count else { throw InlineProtocolError.invalidInput }
      return value
    }
  }
}

private extension [UInt8] {
  var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private func bytes(_ hex: String) -> [UInt8] {
  stride(from: 0, to: hex.count, by: 2).map { offset in
    let start = hex.index(hex.startIndex, offsetBy: offset)
    return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
  }
}
