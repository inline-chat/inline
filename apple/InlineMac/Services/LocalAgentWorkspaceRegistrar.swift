import Darwin
import Foundation

/// A tiny macOS-only client for the bridge's capability-authenticated loopback
/// workspace registrar. It never discovers a socket or reads an app group:
/// the owner-authorized settings document supplies one ephemeral loopback port
/// and service-epoch capability, which this client probes before showing the
/// native folder panel.
enum LocalAgentWorkspaceRegistrar {
  private static let version = 1
  private static let maximumRequestBytes = 8 * 1_024
  private static let maximumResponseBytes = 8 * 1_024
  private static let socketTimeoutSeconds: Int = 3

  static func register(
    folderURL: URL,
    hostInstallationID: String,
    botUserID: Int64,
    port: UInt16,
    capability: String
  ) async throws -> String {
    let response = try await request(
      action: .register,
      hostInstallationID: hostInstallationID,
      botUserID: botUserID,
      port: port,
      capability: capability,
      path: folderURL.path
    )
    guard response.status == "registered", let workspaceID = response.workspaceID else {
      throw Error.rejected(response.detail)
    }
    return workspaceID
  }

  static func isAvailable(
    hostInstallationID: String,
    botUserID: Int64,
    port: UInt16,
    capability: String
  ) async -> Bool {
    guard let response = try? await request(
      action: .probe,
      hostInstallationID: hostInstallationID,
      botUserID: botUserID,
      port: port,
      capability: capability,
      path: nil
    ) else { return false }
    return response.status == "available"
  }

  private enum Action: String, Encodable, Sendable {
    case probe
    case register
  }

  private struct Request: Encodable, Sendable {
    let version: Int
    let action: Action
    let hostInstallationID: String
    let botUserID: Int64
    let capability: String
    let path: String?
  }

  private struct Response: Decodable, Sendable {
    let version: Int
    let status: String
    let workspaceID: String?
    let detail: String?
  }

  private static func request(
    action: Action,
    hostInstallationID: String,
    botUserID: Int64,
    port: UInt16,
    capability: String,
    path: String?
  ) async throws -> Response {
    guard isSafeHostInstallationID(hostInstallationID),
          port >= 1_024,
          isOpaqueCapability(capability)
    else { throw Error.invalidEndpoint }
    let request = Request(
      version: version,
      action: action,
      hostInstallationID: hostInstallationID,
      botUserID: botUserID,
      capability: capability,
      path: path
    )
    return try await Task.detached(priority: .userInitiated) {
      try send(request, port: port)
    }.value
  }

  private static func isSafeHostInstallationID(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128 else { return false }
    return value.utf8.allSatisfy {
      ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95
    }
  }

  private static func isOpaqueCapability(_ value: String) -> Bool {
    guard value.utf8.count >= 32, value.utf8.count <= 128 else { return false }
    return value.utf8.allSatisfy {
      ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 || $0 == 46 || $0 == 58
    }
  }

  private static func send(_ request: Request, port: UInt16) throws -> Response {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw Error.unavailable }
    defer { close(descriptor) }
    try configureTimeout(descriptor)
    try connect(descriptor, toLoopbackPort: port)
    var payload = try JSONEncoder().encode(request)
    guard payload.count < maximumRequestBytes else { throw Error.invalidEndpoint }
    payload.append(0x0A)
    try writeAll(payload, descriptor: descriptor)
    let response = try readLine(descriptor: descriptor)
    let decoded = try JSONDecoder().decode(Response.self, from: response)
    guard decoded.version == version else { throw Error.unsupportedVersion }
    return decoded
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
    while response.count < maximumResponseBytes {
      let count = Darwin.read(descriptor, &byte, 1)
      guard count == 1 else { throw Error.unavailable }
      if byte == 0x0A { return response }
      response.append(byte)
    }
    throw Error.unavailable
  }

  enum Error: LocalizedError {
    case invalidEndpoint
    case unavailable
    case unsupportedVersion
    case rejected(String?)

    var errorDescription: String? {
      switch self {
      case .invalidEndpoint, .unavailable: "The local agent bridge is unavailable."
      case .unsupportedVersion: "The local agent bridge needs an update."
      case .rejected: "That folder could not be registered."
      }
    }
  }
}
