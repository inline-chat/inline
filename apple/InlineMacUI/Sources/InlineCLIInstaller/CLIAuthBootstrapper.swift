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

    let processResult: CLIAuthHandshakeProcessResult
    do {
      processResult = try await CLIAuthHandshakeProcess.run(
        executableURL: installation.executableURL,
        arguments: [
          "--json",
          "--compact",
          "auth",
          "login",
          "--mac-app-bootstrap",
        ],
        environment: Self.sanitizedEnvironment(ProcessInfo.processInfo.environment),
        configuration: CLIAuthHandshakeProcess.Configuration(
          timeout: Self.maximumRuntime,
          maximumReadyBytes: Self.maximumReadyBytes,
          maximumResultBytes: Self.maximumResultBytes,
          maximumErrorBytes: Self.maximumErrorBytes
        )
      ) { readyData in
        let request = try Self.parseReady(readyData)
        try await authorize(request)
      }
    } catch CLIAuthHandshakeProcessFailure.launchFailed {
      throw CLIAuthBootstrapError.couldNotLaunch
    } catch CLIAuthHandshakeProcessFailure.timedOut {
      throw CLIAuthBootstrapError.timedOut
    } catch CLIAuthHandshakeProcessFailure.cancelled {
      throw CancellationError()
    } catch CLIAuthHandshakeProcessFailure.invalidOutputLine(let index, let result) {
      if index == 0 {
        throw CLIAuthBootstrapError.invalidHandshake
      }
      throw CLIAuthBootstrapError.commandFailed(
        Self.commandFailureDetail(
          standardError: result.standardError,
          wasTruncated: result.standardErrorWasTruncated
        )
      )
    } catch {
      throw error
    }

    guard processResult.status == 0 else {
      throw CLIAuthBootstrapError.commandFailed(
        Self.commandFailureDetail(
          standardError: processResult.standardError,
          wasTruncated: processResult.standardErrorWasTruncated
        )
      )
    }
    guard let resultLine = processResult.resultLine else {
      throw CLIAuthBootstrapError.invalidHandshake
    }
    return try Self.parseResult(resultLine)
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

  static func commandFailureDetail(
    standardError: Data,
    wasTruncated: Bool
  ) -> String? {
    guard !standardError.isEmpty || wasTruncated else { return nil }
    if wasTruncated {
      return "The installed CLI reported an authentication error. Its diagnostics were truncated."
    }
    return "The installed CLI reported an authentication error."
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
