import Darwin
import Foundation
import RealtimeV2

/// Exchanges one newly minted CLI credential with the requesting `inline`
/// process over an ephemeral, capability-authenticated loopback listener.
/// No credential is placed in a URL, pasteboard, file, or app-group container.
enum LocalCLIAuthBroker {
  private static let version = 1
  private static let maximumMessageBytes = 8 * 1_024
  private static let socketTimeoutSeconds: Int = 3

  struct Endpoint: Sendable {
    let port: UInt16
    let capability: String

    init?(url: URL) {
      guard url.host?.lowercased() == "cli-auth",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.queryItems?.first(where: { $0.name == "version" })?.value == String(version),
            let portValue = components.queryItems?.first(where: { $0.name == "port" })?.value,
            let port = UInt16(portValue), port >= 1_024,
            let capability = components.queryItems?.first(where: { $0.name == "capability" })?.value,
            isOpaqueCapability(capability)
      else { return nil }
      self.port = port
      self.capability = capability
    }
  }

  struct ClientMetadata: Sendable {
    let deviceID: String
    let deviceName: String?
    let clientVersion: String
    let osVersion: String?
    let verificationCode: String
  }

  static func probe(_ endpoint: Endpoint) async throws -> ClientMetadata {
    let response = try await request(.probe, endpoint: endpoint)
    guard response.status == "available",
          let deviceID = response.deviceID,
          isValidDeviceID(deviceID),
          let clientVersion = response.clientVersion,
          isValidVersion(clientVersion),
          let verificationCode = response.verificationCode,
          isValidVerificationCode(verificationCode),
          isValidDeviceName(response.deviceName),
          isValidOptionalVersion(response.osVersion)
    else { throw Error.rejected(response.detail) }
    return ClientMetadata(
      deviceID: deviceID,
      deviceName: response.deviceName,
      clientVersion: clientVersion,
      osVersion: response.osVersion,
      verificationCode: verificationCode
    )
  }

  static func complete(_ endpoint: Endpoint, token: String, userID: Int64) async throws {
    guard !token.isEmpty, token.utf8.count <= 4 * 1_024 else { throw Error.invalidResponse }
    guard userID > 0 else { throw Error.invalidResponse }
    let response = try await request(.complete, endpoint: endpoint, token: token, userID: userID)
    guard response.status == "accepted" else { throw Error.rejected(response.detail) }
  }

  static func createAndDeliverSession(
    _ endpoint: Endpoint,
    client: ClientMetadata,
    realtime: RealtimeV2
  ) async throws -> Int64 {
    let session = try await realtime.createCliSession(
      deviceID: client.deviceID,
      deviceName: client.deviceName,
      clientVersion: client.clientVersion,
      osVersion: client.osVersion
    )
    do {
      try await complete(endpoint, token: session.token, userID: session.userID)
    } catch {
      _ = try? await realtime.revokeSession(session.sessionID)
      throw error
    }
    return session.sessionID
  }

  static func cancel(_ endpoint: Endpoint, detail: String) async {
    _ = try? await request(.cancel, endpoint: endpoint, detail: detail)
  }

  private enum Action: String, Encodable, Sendable {
    case probe
    case complete
    case cancel
  }

  private struct Request: Encodable, Sendable {
    let version: Int
    let action: Action
    let capability: String
    let token: String?
    let userID: Int64?
    let detail: String?
  }

  private struct Response: Decodable, Sendable {
    let version: Int
    let status: String
    let deviceID: String?
    let deviceName: String?
    let clientVersion: String?
    let osVersion: String?
    let verificationCode: String?
    let detail: String?
  }

  private static func request(
    _ action: Action,
    endpoint: Endpoint,
    token: String? = nil,
    userID: Int64? = nil,
    detail: String? = nil
  ) async throws -> Response {
    let request = Request(
      version: version,
      action: action,
      capability: endpoint.capability,
      token: token,
      userID: userID,
      detail: detail
    )
    return try await Task.detached(priority: .userInitiated) {
      try send(request, port: endpoint.port)
    }.value
  }

  private static func isOpaqueCapability(_ value: String) -> Bool {
    guard value.utf8.count >= 32, value.utf8.count <= 128 else { return false }
    return value.utf8.allSatisfy {
      ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95
    }
  }

  private static func isValidDeviceID(_ value: String) -> Bool {
    guard value.hasPrefix("cli_") else { return false }
    let suffix = value.dropFirst(4).utf8
    guard (16 ... 96).contains(suffix.count) else { return false }
    return suffix.allSatisfy {
      ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95
    }
  }

  private static func isValidVerificationCode(_ value: String) -> Bool {
    value.utf8.count == 6 && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
  }

  private static func isValidDeviceName(_ value: String?) -> Bool {
    guard let value else { return true }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !normalized.isEmpty && normalized.utf16.count <= 128 &&
      !normalized.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }

  private static func isValidOptionalVersion(_ value: String?) -> Bool {
    value.map(isValidVersion) ?? true
  }

  private static func isValidVersion(_ value: String) -> Bool {
    guard value.utf8.count <= 64 else { return false }
    let segments = value.split(separator: ".", omittingEmptySubsequences: false)
    guard (1 ... 4).contains(segments.count) else { return false }
    return segments.allSatisfy { segment in
      !segment.isEmpty && segment.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } &&
        (segment == "0" || segment.first != "0")
    }
  }

  private static func send(_ request: Request, port: UInt16) throws -> Response {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw Error.unavailable }
    defer { close(descriptor) }
    try configureTimeout(descriptor)
    try connect(descriptor, toLoopbackPort: port)

    var payload = try JSONEncoder().encode(request)
    guard payload.count < maximumMessageBytes else { throw Error.invalidResponse }
    payload.append(0x0A)
    try writeAll(payload, descriptor: descriptor)

    let responseData = try readLine(descriptor: descriptor)
    let response = try JSONDecoder().decode(Response.self, from: responseData)
    guard response.version == version else { throw Error.unsupportedVersion }
    return response
  }

  private static func configureTimeout(_ descriptor: Int32) throws {
    var timeout = timeval(tv_sec: socketTimeoutSeconds, tv_usec: 0)
    guard setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
          setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
    else { throw Error.unavailable }
  }

  private static func connect(_ descriptor: Int32, toLoopbackPort port: UInt16) throws {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else { throw Error.unavailable }
  }

  private static func writeAll(_ data: Data, descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        guard written > 0 else { throw Error.unavailable }
        offset += written
      }
    }
  }

  private static func readLine(descriptor: Int32) throws -> Data {
    var response = Data()
    var byte: UInt8 = 0
    while response.count < maximumMessageBytes {
      let count = Darwin.read(descriptor, &byte, 1)
      guard count == 1 else { throw Error.unavailable }
      if byte == 0x0A { return response }
      response.append(byte)
    }
    throw Error.invalidResponse
  }

  enum Error: LocalizedError {
    case unavailable
    case unsupportedVersion
    case invalidResponse
    case rejected(String?)

    var errorDescription: String? {
      switch self {
      case .unavailable: "The requesting Inline CLI is no longer available."
      case .unsupportedVersion: "The requesting Inline CLI needs an update."
      case .invalidResponse: "The requesting Inline CLI returned an invalid response."
      case let .rejected(detail): detail ?? "The requesting Inline CLI rejected the handoff."
      }
    }
  }
}
