import Foundation
import Testing
@testable import InlineProtocol

@Suite("Inline Protocol server clock")
struct ServerClockTests {
  private let authKey = Array(UInt8.min...UInt8.max)
  private let padding = Array(UInt8(0xa0)...UInt8(0xb7))

  private func record(direction: InlineProtocolDirection, messageID: Int64) throws -> [UInt8] {
    try InlineSecureTransport.encryptRecord(
      authKey: authKey,
      direction: direction,
      fields: InlineEncryptedRecordFields(
        serverSalt: 1, sessionID: 2, messageID: messageID, sequenceNumber: 1,
        body: [0xa6, 0x4a, 0x7d, 0xeb, 3, 0, 0, 0]
      ),
      padding: padding
    )
  }

  @Test("accepts a server record whatever its time, so a clock correction always gets through")
  func serverRecordsIgnoreTheLocalClock() throws {
    let messageID: Int64 = (1_700_000_000 << 32) | 1
    let server = try record(direction: .serverToClient, messageID: messageID)
    for nowSeconds: Int64 in [1_700_000_000 - 86_400, 1_700_000_000 + 86_400] {
      let fields = try InlineSecureTransport.decryptRecord(
        server, authKey: authKey, direction: .serverToClient,
        expectedSessionID: 2, validServerSalts: [1], nowSeconds: nowSeconds
      )
      #expect(fields.messageID == messageID)
    }
  }

  @Test("still holds client records to the window on the server side")
  func clientRecordsKeepTheWindow() throws {
    let client = try record(direction: .clientToServer, messageID: (1_700_000_000 << 32) | 4)
    for nowSeconds: Int64 in [1_700_000_000 + 301, 1_700_000_000 - 31] {
      #expect(throws: (any Error).self) {
        try InlineSecureTransport.decryptRecord(
          client, authKey: authKey, direction: .clientToServer,
          expectedSessionID: 2, validServerSalts: [1], nowSeconds: nowSeconds
        )
      }
    }
  }

  @Test("learns, persists and reloads the server time offset")
  func offsetPersists() throws {
    let suite = "InlineProtocolServerClockTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let clock = InlineProtocolServerClockOffset(defaults: defaults, key: "offset")
    #expect(clock.offsetMilliseconds == nil)
    #expect(clock.estimatedServerUnixMilliseconds(wallMilliseconds: 5_000) == 5_000)

    clock.record(serverUnixMilliseconds: 1_000_600_000, wallMilliseconds: 1_000_000_000)
    #expect(clock.offsetMilliseconds == 600_000)
    #expect(clock.estimatedServerUnixMilliseconds(wallMilliseconds: 2_000) == 602_000)

    // Small moves update memory but not the saved value; a new launch starts from the saved one.
    clock.record(serverUnixMilliseconds: 1_000_600_500, wallMilliseconds: 1_000_000_000)
    #expect(clock.offsetMilliseconds == 600_500)
    #expect(InlineProtocolServerClockOffset(defaults: defaults, key: "offset").offsetMilliseconds == 600_000)
    clock.record(serverUnixMilliseconds: 999_000_000, wallMilliseconds: 1_000_000_000)
    #expect(InlineProtocolServerClockOffset(defaults: defaults, key: "offset").offsetMilliseconds == -1_000_000)

    clock.reset()
    #expect(clock.offsetMilliseconds == nil)
    #expect(InlineProtocolServerClockOffset(defaults: defaults, key: "offset").offsetMilliseconds == nil)
  }
}

/// Runs only against a local Realtime V3 server whose clock is skewed, for example the scratch
/// skew server: INLINE_V3_SKEW_URL=ws://127.0.0.1:47311 INLINE_V3_SKEW_RING=/path/ring.json
/// INLINE_V3_SKEW_OFFSET_MS=600000 swift test --filter ServerClockLiveTests
@Suite("Inline Protocol server clock against a skewed server", .serialized)
struct ServerClockLiveTests {
  @Test("logs in, binds, reconnects and calls RPCs when the device clock is wrong",
        .enabled(if: ProcessInfo.processInfo.environment["INLINE_V3_SKEW_URL"] != nil))
  func skewedServer() async throws {
    let environment = ProcessInfo.processInfo.environment
    let urlString = try #require(environment["INLINE_V3_SKEW_URL"])
    let ringPath = try #require(environment["INLINE_V3_SKEW_RING"])
    let offsetString = try #require(environment["INLINE_V3_SKEW_OFFSET_MS"])
    let url = try #require(URL(string: urlString))
    let ring = try InlineProtocolTrustRoots.decodeRing(Data(contentsOf: URL(fileURLWithPath: ringPath)))
    let expected = try #require(Int64(offsetString))
    let clock = InlineProtocolServerClockOffset.shared
    clock.reset()
    defer { clock.reset() }

    let permanent = try await InlineProtocolV3Connection.connect(.init(url: url, rsaPublicKeys: ring))
    var begin = AuthBeginRequest()
    begin.email = "skew@example.com"
    let challenge = try await permanent.authBegin(begin)
    var complete = AuthCompleteRequest()
    complete.challengeID = challenge.challengeID
    complete.code = "123456"
    _ = try await permanent.authComplete(complete)

    let temporary = try await InlineProtocolV3Connection.connect(
      .init(url: url, rsaPublicKeys: ring, temporary: true)
    )
    try await temporary.bindTemporary(to: await permanent.authorization)
    try await getMe(temporary)
    let learned = try #require(clock.offsetMilliseconds)
    #expect(abs(learned - expected) < 5_000)
    let cached = await temporary.authorization
    await temporary.close()

    let reconnected = try await InlineProtocolV3Connection.connect(.reconnect(url: url, authorization: cached))
    try await getMe(reconnected)
    await reconnected.close()

    // A launch that never learned the offset starts from the device clock and resyncs on 16/17.
    clock.reset()
    let fresh = try await InlineProtocolV3Connection.connect(.reconnect(url: url, authorization: cached))
    try await getMe(fresh)
    let relearned = try #require(clock.offsetMilliseconds)
    #expect(abs(relearned - expected) < 5_000)
    await fresh.close()
    await permanent.close()
  }

  private func getMe(_ connection: InlineProtocolV3Connection) async throws {
    var request = RealtimeV3Request()
    request.rpc = .with {
      $0.method = .getMe
      $0.input = .getMe(GetMeInput())
    }
    let response = try await connection.invoke(request)
    guard case .rpcResult = response.body else {
      Issue.record("GET_ME did not return an RPC result: \(response)")
      return
    }
  }
}
