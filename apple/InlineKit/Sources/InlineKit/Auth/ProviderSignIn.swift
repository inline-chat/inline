import Auth
import Combine
import CryptoKit
import Foundation
import Logger

public enum ProviderSignInProvider: String, Hashable, Sendable {
  case google
  case apple
}

public struct ProviderSignInCompletion: Equatable, Sendable {
  public let id: UUID
  public let pendingSetup: Bool
  public let userCreatedAt: Date
}

@MainActor
public final class ProviderSignInCoordinator: ObservableObject {
  public static let shared = ProviderSignInCoordinator()

  @Published public private(set) var completion: ProviderSignInCompletion?
  @Published public private(set) var errorMessage: String?
  @Published public private(set) var isRedeeming = false

  private let log = Log.scoped("ProviderSignIn")
  private var pendingCodeVerifier: String?

  private init() {}

  public func startURL(for provider: ProviderSignInProvider) async throws -> URL {
    completion = nil
    errorMessage = nil
    let codeVerifier = Self.randomCodeVerifier()
    pendingCodeVerifier = codeVerifier
    let sessionInfo = SessionInfo.get()
    let deviceID = try await DeviceIdentifier.shared.getIdentifier()
    var components = URLComponents(string: "\(ApiClient.baseURL)/auth/provider/start")
    components?.queryItems = [
      URLQueryItem(name: "provider", value: provider.rawValue),
      URLQueryItem(name: "purpose", value: "app"),
      URLQueryItem(name: "callback_scheme", value: InlineDeepLink.configuredScheme),
      URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: codeVerifier)),
      URLQueryItem(name: "client_type", value: sessionInfo?.clientType ?? platformClientType),
      URLQueryItem(name: "device_id", value: deviceID),
      URLQueryItem(name: "client_version", value: sessionInfo?.clientVersion),
      URLQueryItem(name: "os_version", value: sessionInfo?.osVersion),
      URLQueryItem(name: "device_name", value: sessionInfo?.deviceName),
      URLQueryItem(name: "timezone", value: sessionInfo?.timezone),
    ].filter { $0.value?.isEmpty == false }
    guard let url = components?.url else { throw APIError.invalidURL }
    return url
  }

  public func canHandle(_ url: URL) -> Bool {
    guard InlineDeepLink.isCurrentAppScheme(url.scheme), url.host?.lowercased() == "auth" else {
      return false
    }
    return url.pathComponents.filter { $0 != "/" } == ["provider"]
  }

  public func handleCallback(_ url: URL) async {
    guard canHandle(url), !isRedeeming else { return }
    let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    if let callbackError = queryItems?.first(where: { $0.name == "error" })?.value {
      pendingCodeVerifier = nil
      errorMessage = callbackError == "cancelled"
        ? String(localized: "Sign-in was cancelled. No changes were made.")
        : String(localized: "Inline could not finish signing you in. Please try again.")
      return
    }
    guard let ticket = queryItems?.first(where: { $0.name == "ticket" })?.value,
      !ticket.isEmpty
    else {
      errorMessage = String(localized: "Sign-in could not finish. Return to Inline and try again.")
      return
    }
    guard let codeVerifier = pendingCodeVerifier else {
      errorMessage = String(localized: "This sign-in is no longer active. Please try again.")
      return
    }
    pendingCodeVerifier = nil

    isRedeeming = true
    errorMessage = nil
    defer { isRedeeming = false }
    do {
      let result = try await ApiClient.shared.redeemProviderAuth(
        ticket: ticket,
        codeVerifier: codeVerifier
      )
      if let token = result.token {
        await Auth.shared.saveCredentials(token: token, userId: result.userId)
      }
      try await AppDatabase.authenticated()
      _ = try await AppDatabase.shared.dbWriter.write { db in
        try result.user.saveFull(db)
      }
      Analytics.identify(
        userId: result.userId,
        email: result.user.email,
        name: result.user.anyName,
        username: result.user.username
      )
      completion = ProviderSignInCompletion(
        id: UUID(),
        pendingSetup: result.user.pendingSetup == true || result.user.firstName?.isEmpty != false,
        userCreatedAt: Date(timeIntervalSince1970: TimeInterval(result.user.date))
      )
    } catch {
      log.error("Failed to redeem provider sign-in", error: error)
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  public func recordStartFailure(_ error: Error) {
    log.error("Failed to start provider sign-in", error: error)
    pendingCodeVerifier = nil
    errorMessage = Self.userFacingMessage(for: error)
  }

  public func clearError() {
    errorMessage = nil
  }

  public func cancelPendingAttempt() {
    pendingCodeVerifier = nil
  }

  private static func userFacingMessage(for error: Error) -> String {
    switch error {
      case APIError.rateLimited:
        String(localized: "Too many sign-in attempts. Wait a moment and try again.")
      case APIError.networkError:
        String(localized: "Inline could not connect. Check your connection and try again.")
      default:
        String(localized: "Inline could not finish signing you in. Please try again.")
    }
  }

  private static func randomCodeVerifier() -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    return Data(bytes).base64URLEncodedString()
  }

  private static func codeChallenge(for verifier: String) -> String {
    Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
  }

  private var platformClientType: String {
    #if os(iOS)
    "ios"
    #else
    "macos"
    #endif
  }
}

private extension Data {
  func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
