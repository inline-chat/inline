import Foundation

public enum InlineProtocolTrustRootError: Error, Equatable, Sendable, LocalizedError {
  case unavailable
  case invalidVerificationDocument
  case invalidVerificationURL
  case verificationHTTPStatus(Int)

  public var errorDescription: String? {
    switch self {
    case .unavailable: "No Inline Protocol RSA public keys are available."
    case .invalidVerificationDocument: "The Inline Protocol verification document is invalid."
    case .invalidVerificationURL: "The Inline Protocol verification URL is invalid."
    case let .verificationHTTPStatus(status):
      "The Inline Protocol verification endpoint returned HTTP \(status)."
    }
  }
}

public enum InlineProtocolTrustRoots {
  private struct Ring: Decodable {
    let rsaPublicKeyRing: [Entry]
  }

  private struct Entry: Decodable {
    let modulus: String
    let exponent: String
    let fingerprint: String
  }

  private struct VerificationDocument: Decodable {
    let protocolName: String
    let protocolVersion: Int
    let applicationContract: String
    let applicationContractVersion: Int
    let status: String
    let websocketPath: String
    let rsaPublicKeyRing: [Entry]

    enum CodingKeys: String, CodingKey {
      case protocolName = "protocol"
      case protocolVersion
      case applicationContract
      case applicationContractVersion
      case status
      case websocketPath
      case rsaPublicKeyRing
    }
  }

  /// Production's overlapping pinned RSA ring. These are public verification keys only;
  /// release clients must never discover or replace them from an unauthenticated endpoint.
  private static let productionRingJSON = #"{"rsaPublicKeyRing":[{"modulus":"y4mCEOAFrQU02g6WBGLvsy6hBh9jOfV6Hg6lvKvnRKj2vybdLTISXilcYbN2ItUfXhFf7Tk660OLhD7lBv2Pme9YVmWswHJ9j7PyyIa6klTiBLSADPPCuknvID1X7bX-Ut5IwmJDciSITHy0Qxf5yGnhRWPWOgxWDt4EdwHiOd9uHwCxLn9k8LfIXN2DOT8aPH306IB0IWMsTlnXBZ7om8nZniJG0NWG1u-BJDEk4Hz8eko1cF4wc-naVY4qcDh9zD9iXrbMJ5b8aw2JG11dvJGEBmWqjPcPJy1VqFNAZOxGUf-LXWRTnNuwECRpgvqm5oO_CFfwXUvM5W1Tw7lIVQ","exponent":"AQAB","fingerprint":"-8339382514522710386"},{"modulus":"mHcArJ0brV69p-pgk5aHpEGWMw1sp-fB7CIxqNTQU9_cTBTUzsBykiEEkZfSj1bCYuTkyhPmlsrf4yA9vP8I5rQqf7UGD1Za_W2qbbv3Wv4C3w4yV-bNJUlxG4qokDHszKgDcNumLJq8uIItXnzeg64UzKW2Bm9KikLtJTB-tq18rrNZ43xS5sZK9HHjvO3i--PdpqB0JVSD4VmjIbXHgq7v9czsYbuqlDn4mCj0rCKylQPxCKVrxbtcuP_brwW-foIkjjX8T7Q5Mi_0Zqx-VZZY7AkT8L7LJH5Lgje_IxYQp2zcLjCQf_ZNioCR0xCPMySvJnBTmVwa65wH0alkPQ","exponent":"AQAB","fingerprint":"-3957383261870667958"}]}"#

  public static let production: [InlineProtocolRSAPublicKey] = {
    (try? decodeRing(Data(productionRingJSON.utf8))) ?? []
  }()

  public static func decodeRing(_ data: Data) throws -> [InlineProtocolRSAPublicKey] {
    let ring = try JSONDecoder().decode(Ring.self, from: data)
    return try decodeEntries(ring.rsaPublicKeyRing)
  }

  public static func decodeVerificationDocument(
    _ data: Data,
    expectedWebsocketPath: String
  ) throws -> [InlineProtocolRSAPublicKey] {
    let document = try JSONDecoder().decode(VerificationDocument.self, from: data)
    guard document.protocolName == "Inline Protocol",
          document.protocolVersion == 1,
          document.applicationContract == "Realtime V3",
          document.applicationContractVersion == 3,
          document.status == "ready",
          document.websocketPath == expectedWebsocketPath
    else { throw InlineProtocolTrustRootError.invalidVerificationDocument }
    let keys = try decodeEntries(document.rsaPublicKeyRing)
    guard !keys.isEmpty else { throw InlineProtocolTrustRootError.unavailable }
    return keys
  }

  private static func decodeEntries(_ entries: [Entry]) throws -> [InlineProtocolRSAPublicKey] {
    try entries.map { entry in
      guard let fingerprint = Int64(entry.fingerprint) else { throw InlineProtocolError.invalidInput }
      return try InlineProtocolRSAPublicKey(
        modulus: decodeBase64URL(entry.modulus),
        exponent: decodeBase64URL(entry.exponent),
        fingerprint: fingerprint
      )
    }
  }

  /// Plaintext local Debug sockets already have no authenticated network boundary, so their
  /// process-local development keys may be resolved from the matching verification endpoint.
  /// Release builds and every TLS WebSocket remain pinned-only.
  public static func supportsLocalDebugDiscovery(
    for url: URL,
    allowedDevelopmentHost: String?
  ) -> Bool {
    #if DEBUG
    guard url.scheme == "ws", let host = url.host?.lowercased() else { return false }
    let localHosts = ["localhost", "127.0.0.1", "::1"]
    return localHosts.contains(host) || host == allowedDevelopmentHost?.lowercased()
    #else
    false
    #endif
  }

  public static func resolve(
    for websocketURL: URL,
    pinnedKeys: [InlineProtocolRSAPublicKey],
    allowedDevelopmentHost: String?
  ) async throws -> [InlineProtocolRSAPublicKey] {
    #if DEBUG
    if supportsLocalDebugDiscovery(
      for: websocketURL,
      allowedDevelopmentHost: allowedDevelopmentHost
    ) {
      guard var components = URLComponents(url: websocketURL, resolvingAgainstBaseURL: false) else {
        throw InlineProtocolTrustRootError.invalidVerificationURL
      }
      components.scheme = "http"
      components.path = "/.well-known/inline-protocol"
      components.query = nil
      components.fragment = nil
      guard let verificationURL = components.url else {
        throw InlineProtocolTrustRootError.invalidVerificationURL
      }
      var request = URLRequest(url: verificationURL, cachePolicy: .reloadIgnoringLocalCacheData)
      request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
      let session = URLSession(configuration: .ephemeral)
      defer { session.finishTasksAndInvalidate() }
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw InlineProtocolTrustRootError.invalidVerificationURL
      }
      guard http.url?.scheme == verificationURL.scheme,
            http.url?.host?.lowercased() == verificationURL.host?.lowercased(),
            http.url?.port == verificationURL.port,
            http.url?.path == verificationURL.path
      else { throw InlineProtocolTrustRootError.invalidVerificationURL }
      guard (200 ... 299).contains(http.statusCode) else {
        throw InlineProtocolTrustRootError.verificationHTTPStatus(http.statusCode)
      }
      return try decodeVerificationDocument(data, expectedWebsocketPath: websocketURL.path)
    }
    #endif

    guard !pinnedKeys.isEmpty else { throw InlineProtocolTrustRootError.unavailable }
    return pinnedKeys
  }

  private static func decodeBase64URL(_ value: String) throws -> [UInt8] {
    var base64 = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64) else { throw InlineProtocolError.invalidInput }
    return Array(data)
  }
}
