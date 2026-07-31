import Darwin
import Foundation
import Security

public struct CLIAuthBootstrapRequest: Equatable, Sendable {
  public let callbackURL: URL

  public init(callbackURL: URL) {
    self.callbackURL = callbackURL
  }
}

public struct CLIAuthBootstrapResult: Equatable, Sendable {
  public let userID: Int64
  public let profileLoaded: Bool
  public let warning: String?

  public init(userID: Int64, profileLoaded: Bool, warning: String?) {
    self.userID = userID
    self.profileLoaded = profileLoaded
    self.warning = warning
  }
}

public enum CLIAuthBootstrapError: LocalizedError, Equatable, Sendable {
  case unavailableInSandbox
  case couldNotLaunch
  case invalidHandshake
  case timedOut
  case commandFailed(String?)

  public var errorDescription: String? {
    switch self {
    case .unavailableInSandbox:
      "This build of Inline cannot sign in the CLI directly. Run `inline login` in Terminal instead."
    case .couldNotLaunch:
      "Inline could not launch the installed CLI."
    case .invalidHandshake:
      "The installed CLI returned an invalid sign-in response. Update it and try again."
    case .timedOut:
      "The installed CLI did not finish signing in within two minutes."
    case let .commandFailed(detail):
      detail ?? "The installed CLI could not finish signing in."
    }
  }
}

public struct CLIAuthBootstrapper: Sendable {
  private static let protocolVersion = 1
  private static let maximumReadyBytes = 8 * 1_024
  private static let maximumResultBytes = 256 * 1_024
  private static let maximumErrorBytes = 8 * 1_024
  private static let maximumRuntime: TimeInterval = 125

  private let configuration: CLIInstallerConfiguration

  public init(configuration: CLIInstallerConfiguration = .production) {
    self.configuration = configuration
  }

  public static var isSupportedInCurrentProcess: Bool {
    !isCurrentProcessSandboxed()
  }

  @concurrent public func authenticate(
    installation: CLIInstallation,
    authorize: @escaping @MainActor @Sendable (CLIAuthBootstrapRequest) async throws -> Void
  ) async throws -> CLIAuthBootstrapResult {
    guard Self.isSupportedInCurrentProcess else {
      throw CLIAuthBootstrapError.unavailableInSandbox
    }

    try CLIExecutableVerifier.verify(
      installation.executableURL,
      configuration: configuration
    )
    guard FileManager.default.isExecutableFile(atPath: installation.executableURL.path) else {
      throw CLIAuthBootstrapError.couldNotLaunch
    }

    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = installation.executableURL
    process.arguments = [
      "--json",
      "--compact",
      "auth",
      "login",
      "--mac-app-bootstrap",
    ]
    process.environment = Self.sanitizedEnvironment(ProcessInfo.processInfo.environment)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = standardOutput
    process.standardError = standardError

    do {
      try process.run()
    } catch {
      throw CLIAuthBootstrapError.couldNotLaunch
    }

    let timeoutState = TimeoutState()
    let timeoutTask = DispatchWorkItem {
      guard process.isRunning else { return }
      timeoutState.markTimedOut()
      Self.terminate(process)
    }
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + Self.maximumRuntime,
      execute: timeoutTask
    )
    defer { timeoutTask.cancel() }

    let request: CLIAuthBootstrapRequest
    do {
      let readyData = try Self.readLine(
        from: standardOutput.fileHandleForReading,
        maximumBytes: Self.maximumReadyBytes
      )
      request = try Self.parseReady(readyData)
    } catch {
      Self.stop(process)
      throw timeoutState.didTimeOut ? CLIAuthBootstrapError.timedOut : CLIAuthBootstrapError.invalidHandshake
    }

    do {
      try await authorize(request)
    } catch {
      Self.stop(process)
      throw error
    }

    let resultData: Data
    do {
      resultData = try Self.readLine(
        from: standardOutput.fileHandleForReading,
        maximumBytes: Self.maximumResultBytes
      )
    } catch {
      Self.stop(process)
      if timeoutState.didTimeOut {
        throw CLIAuthBootstrapError.timedOut
      }
      let detail = Self.readError(from: standardError.fileHandleForReading)
      throw CLIAuthBootstrapError.commandFailed(detail)
    }

    process.waitUntilExit()
    guard !timeoutState.didTimeOut else {
      throw CLIAuthBootstrapError.timedOut
    }
    guard process.terminationStatus == 0 else {
      let detail = Self.readError(from: standardError.fileHandleForReading)
      throw CLIAuthBootstrapError.commandFailed(detail)
    }
    return try Self.parseResult(resultData)
  }

  private struct ReadyPayload: Decodable {
    let version: Int
    let status: String
    let callbackURL: URL

    private enum CodingKeys: String, CodingKey {
      case version
      case status
      case callbackURL = "callbackUrl"
    }
  }

  private struct ResultPayload: Decodable {
    let status: String
    let userID: Int64
    let tokenSaved: Bool
    let profileLoaded: Bool
    let warning: String?

    private enum CodingKeys: String, CodingKey {
      case status
      case userID = "userId"
      case tokenSaved
      case profileLoaded
      case warning
    }
  }

  static func parseReady(_ data: Data) throws -> CLIAuthBootstrapRequest {
    guard let payload = try? JSONDecoder().decode(ReadyPayload.self, from: data) else {
      throw CLIAuthBootstrapError.invalidHandshake
    }
    guard payload.version == protocolVersion,
          payload.status == "ready",
          let components = URLComponents(url: payload.callbackURL, resolvingAgainstBaseURL: false),
          components.scheme == "inline",
          components.host?.lowercased() == "cli-auth",
          components.user == nil,
          components.password == nil,
          components.fragment == nil else {
      throw CLIAuthBootstrapError.invalidHandshake
    }
    return CLIAuthBootstrapRequest(callbackURL: payload.callbackURL)
  }

  static func parseResult(_ data: Data) throws -> CLIAuthBootstrapResult {
    guard let payload = try? JSONDecoder().decode(ResultPayload.self, from: data) else {
      throw CLIAuthBootstrapError.invalidHandshake
    }
    guard payload.status == "authenticated", payload.tokenSaved, payload.userID > 0 else {
      throw CLIAuthBootstrapError.invalidHandshake
    }
    return CLIAuthBootstrapResult(
      userID: payload.userID,
      profileLoaded: payload.profileLoaded,
      warning: payload.warning
    )
  }

  static func sanitizedEnvironment(_ environment: [String: String]) -> [String: String] {
    var sanitized = environment.filter { !$0.key.hasPrefix("INLINE_") }
    sanitized["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    return sanitized
  }

  private static func readLine(from handle: FileHandle, maximumBytes: Int) throws -> Data {
    var data = Data()
    while data.count < maximumBytes {
      guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else {
        throw CLIAuthBootstrapError.invalidHandshake
      }
      if byte[0] == 0x0A { return data }
      data.append(byte)
    }
    throw CLIAuthBootstrapError.invalidHandshake
  }

  private static func readError(from handle: FileHandle) -> String? {
    let data = (try? handle.read(upToCount: maximumErrorBytes)) ?? Data()
    let detail = (String(data: data, encoding: .utf8) ?? "")
      .unicodeScalars
      .filter { !CharacterSet.controlCharacters.contains($0) }
      .prefix(500)
    let normalized = String(String.UnicodeScalarView(detail)).trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  private static func stop(_ process: Process) {
    Self.terminate(process)
    process.waitUntilExit()
  }

  private static func terminate(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(1)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
    }
  }

  private static func isCurrentProcessSandboxed() -> Bool {
    guard let task = SecTaskCreateFromSelf(nil),
          let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.app-sandbox" as CFString,
            nil
          ) else { return false }
    return value as? Bool == true
  }
}

private final class TimeoutState: @unchecked Sendable {
  private let lock = NSLock()
  private var timedOut = false

  var didTimeOut: Bool {
    lock.withLock { timedOut }
  }

  func markTimedOut() {
    lock.withLock { timedOut = true }
  }
}
