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
  public let userId: Int64
  public let pendingSetup: Bool
  public let userCreatedAt: Date
}

struct ProviderSignInPendingAttempt: Equatable, Sendable {
  let provider: ProviderSignInProvider
  let codeVerifier: String
  let codeChallenge: String
  let generation: UUID
}

struct ProviderSignInAttemptState: Sendable {
  private(set) var pending: ProviderSignInPendingAttempt?

  mutating func begin(
    provider: ProviderSignInProvider,
    codeVerifier: String,
    codeChallenge: String,
    generation: UUID = UUID()
  ) -> ProviderSignInPendingAttempt {
    let attempt = ProviderSignInPendingAttempt(
      provider: provider,
      codeVerifier: codeVerifier,
      codeChallenge: codeChallenge,
      generation: generation
    )
    pending = attempt
    return attempt
  }

  func current(generation: UUID) -> Bool {
    pending?.generation == generation
  }

  func matching(codeChallenge: String) -> ProviderSignInPendingAttempt? {
    pending?.codeChallenge == codeChallenge ? pending : nil
  }

  @discardableResult
  mutating func take(codeChallenge: String) -> ProviderSignInPendingAttempt? {
    guard let attempt = matching(codeChallenge: codeChallenge) else { return nil }
    pending = nil
    return attempt
  }

  mutating func cancel(generation: UUID) {
    guard current(generation: generation) else { return }
    pending = nil
  }

  mutating func cancel(codeChallenge: String) {
    _ = take(codeChallenge: codeChallenge)
  }

  mutating func cancel() {
    pending = nil
  }
}

@MainActor
public final class ProviderSignInCoordinator: ObservableObject {
  public static let shared = ProviderSignInCoordinator()

  @Published public private(set) var completion: ProviderSignInCompletion?
  @Published public private(set) var errorMessage: String?
  @Published public private(set) var isRedeeming = false

  private let log = Log.scoped("ProviderSignIn")
  private var attemptState = ProviderSignInAttemptState()
  private var redeemingGeneration: UUID?

  private init() {}

  public func startURL(for provider: ProviderSignInProvider) async throws -> URL {
    completion = nil
    errorMessage = nil
    let codeVerifier = Self.randomCodeVerifier()
    let attempt = attemptState.begin(
      provider: provider,
      codeVerifier: codeVerifier,
      codeChallenge: Self.codeChallenge(for: codeVerifier)
    )

    do {
      let sessionInfo = SessionInfo.get()
      let deviceID = try await DeviceIdentifier.shared.getIdentifier()
      guard attemptState.current(generation: attempt.generation) else { throw CancellationError() }
      var components = URLComponents(string: "\(ApiClient.baseURL)/auth/provider/start")
      components?.queryItems = [
        URLQueryItem(name: "provider", value: provider.rawValue),
        URLQueryItem(name: "purpose", value: "app"),
        URLQueryItem(name: "callback_scheme", value: InlineDeepLink.configuredScheme),
        URLQueryItem(name: "code_challenge", value: attempt.codeChallenge),
        URLQueryItem(name: "client_type", value: sessionInfo?.clientType ?? platformClientType),
        URLQueryItem(name: "device_id", value: deviceID),
        URLQueryItem(name: "client_version", value: sessionInfo?.clientVersion),
        URLQueryItem(name: "os_version", value: sessionInfo?.osVersion),
        URLQueryItem(name: "device_name", value: sessionInfo?.deviceName),
        URLQueryItem(name: "timezone", value: sessionInfo?.timezone),
      ].filter { $0.value?.isEmpty == false }
      guard let url = components?.url else { throw APIError.invalidURL }
      return url
    } catch {
      guard attemptState.current(generation: attempt.generation) else { throw error }
      attemptState.cancel(generation: attempt.generation)
      if !(error is CancellationError) {
        log.error("Failed to start provider sign-in", error: error)
        errorMessage = Self.userFacingMessage(for: error)
      }
      throw error
    }
  }

  public func canHandle(_ url: URL) -> Bool {
    guard InlineDeepLink.isCurrentAppScheme(url.scheme), url.host?.lowercased() == "auth" else {
      return false
    }
    return url.pathComponents.filter { $0 != "/" } == ["provider"]
  }

  public func handleCallback(_ url: URL) async {
    guard canHandle(url) else { return }
    let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    guard let callbackChallenge = queryItems?.first(where: { $0.name == "code_challenge" })?.value,
      !callbackChallenge.isEmpty,
      let attempt = attemptState.matching(codeChallenge: callbackChallenge),
      !isRedeeming
    else {
      log.warning("Ignored provider callback that did not match the active attempt")
      return
    }

    if let callbackError = queryItems?.first(where: { $0.name == "error" })?.value {
      attemptState.cancel(codeChallenge: callbackChallenge)
      errorMessage = callbackError == "cancelled"
        ? String(localized: "Sign-in was cancelled. No changes were made.")
        : String(localized: "Inline could not finish signing you in. Please try again.")
      return
    }
    guard let ticket = queryItems?.first(where: { $0.name == "ticket" })?.value,
      !ticket.isEmpty
    else {
      attemptState.cancel(codeChallenge: callbackChallenge)
      errorMessage = String(localized: "Sign-in could not finish. Return to Inline and try again.")
      return
    }
    guard attemptState.take(codeChallenge: callbackChallenge) != nil else { return }

    isRedeeming = true
    redeemingGeneration = attempt.generation
    errorMessage = nil
    var redeemedToken: String?
    defer {
      if redeemingGeneration == attempt.generation {
        redeemingGeneration = nil
        isRedeeming = false
      }
    }
    do {
      try await AppDatabase.authenticated()
      let result = try await ApiClient.shared.redeemProviderAuth(
        ticket: ticket,
        codeVerifier: attempt.codeVerifier
      )
      redeemedToken = result.token
      _ = try await AppDatabase.shared.dbWriter.write { db in
        try result.user.saveFull(db)
      }
      try await Auth.shared.saveCredentials(token: result.token, userId: result.userId)
      guard redeemingGeneration == attempt.generation else { return }
      Analytics.identify(
        userId: result.userId,
        email: result.user.email,
        name: result.user.anyName,
        username: result.user.username
      )
      completion = ProviderSignInCompletion(
        id: UUID(),
        userId: result.userId,
        pendingSetup: result.user.pendingSetup == true || result.user.firstName?.isEmpty != false,
        userCreatedAt: Date(timeIntervalSince1970: TimeInterval(result.user.date))
      )
    } catch {
      guard redeemingGeneration == attempt.generation else { return }
      if let redeemedToken {
        _ = try? await ApiClient.shared.logout(bearerToken: redeemedToken)
      }
      log.error("Failed to redeem provider sign-in", error: error)
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  public func recordBrowserOpenFailure(_ error: Error, for url: URL) {
    let challenge = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first(where: { $0.name == "code_challenge" })?.value
    guard let challenge, attemptState.matching(codeChallenge: challenge) != nil else { return }
    log.error("Failed to open provider sign-in", error: error)
    attemptState.cancel(codeChallenge: challenge)
    errorMessage = Self.userFacingMessage(for: error)
  }

  public func consumeCompletion(id: UUID) -> ProviderSignInCompletion? {
    guard completion?.id == id else { return nil }
    defer { completion = nil }
    return completion
  }

  public func clearError() {
    errorMessage = nil
  }

  public func cancelPendingAttempt() {
    attemptState.cancel()
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
