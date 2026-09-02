import Auth
import Combine
import CryptoKit
import Foundation
import Logger

public struct ProviderSignInCompletion: Equatable, Sendable {
  public let id: UUID
  public let userId: Int64
  public let pendingSetup: Bool
  public let userCreatedAt: Date
  public let accountMutationToken: AuthAccountMutationToken
}

public struct NativeAppleAuthorizationRequest: Equatable, Sendable {
  public let state: String
  public let nonce: String
}

public struct NativeAppleInviteRequest: Equatable, Sendable {
  public let id: UUID
}

struct ProviderSignInPendingAttempt: Equatable, Sendable {
  let provider: ProviderSignInProvider
  let codeVerifier: String
  let codeChallenge: String
  let generation: UUID
  let nativeAppleState: String?
  let authAttempt: AuthLoginAttempt?
}

struct ProviderSignInAttemptState: Sendable {
  private(set) var pending: ProviderSignInPendingAttempt?
  private(set) var nativePreparationGeneration: UUID?
  private(set) var nativePreparationAuthAttempt: AuthLoginAttempt?

  @discardableResult
  mutating func beginNativePreparation(
    generation: UUID = UUID(),
    authAttempt: AuthLoginAttempt? = nil
  ) -> UUID {
    pending = nil
    nativePreparationGeneration = generation
    nativePreparationAuthAttempt = authAttempt
    return generation
  }

  func isCurrentNativePreparation(generation: UUID) -> Bool {
    nativePreparationGeneration == generation
  }

  mutating func finishNativePreparation(
    generation: UUID,
    codeVerifier: String,
    codeChallenge: String,
    state: String
  ) -> ProviderSignInPendingAttempt? {
    guard isCurrentNativePreparation(generation: generation) else { return nil }
    nativePreparationGeneration = nil
    let authAttempt = nativePreparationAuthAttempt
    nativePreparationAuthAttempt = nil
    return store(
      provider: .apple,
      codeVerifier: codeVerifier,
      codeChallenge: codeChallenge,
      nativeAppleState: state,
      authAttempt: authAttempt,
      generation: generation
    )
  }

  mutating func begin(
    provider: ProviderSignInProvider,
    codeVerifier: String,
    codeChallenge: String,
    nativeAppleState: String? = nil,
    authAttempt: AuthLoginAttempt? = nil,
    generation: UUID = UUID()
  ) -> ProviderSignInPendingAttempt {
    nativePreparationGeneration = nil
    nativePreparationAuthAttempt = nil
    return store(
      provider: provider,
      codeVerifier: codeVerifier,
      codeChallenge: codeChallenge,
      nativeAppleState: nativeAppleState,
      authAttempt: authAttempt,
      generation: generation
    )
  }

  private mutating func store(
    provider: ProviderSignInProvider,
    codeVerifier: String,
    codeChallenge: String,
    nativeAppleState: String?,
    authAttempt: AuthLoginAttempt?,
    generation: UUID
  ) -> ProviderSignInPendingAttempt {
    let attempt = ProviderSignInPendingAttempt(
      provider: provider,
      codeVerifier: codeVerifier,
      codeChallenge: codeChallenge,
      generation: generation,
      nativeAppleState: nativeAppleState,
      authAttempt: authAttempt
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
    nativePreparationGeneration = nil
    nativePreparationAuthAttempt = nil
  }
}

@MainActor
public final class ProviderSignInCoordinator: ObservableObject {
  public static let shared = ProviderSignInCoordinator()

  @Published public private(set) var completion: ProviderSignInCompletion?
  @Published public private(set) var errorMessage: String?
  @Published public private(set) var isRedeeming = false
  @Published public private(set) var nativeAppleInviteRequest: NativeAppleInviteRequest?

  private let log = Log.scoped("ProviderSignIn")
  private var attemptState = ProviderSignInAttemptState()
  private var redeemingGeneration: UUID?
  private var redeemingAuthAttempt: AuthLoginAttempt?
  private var nativeAppleInvite: (attemptId: String, continuation: String)?

  private init() {}

  public func startURL(for provider: ProviderSignInProvider) async throws -> URL {
    let authAttempt = try await Auth.shared.beginLoginAttempt()
    completion = nil
    errorMessage = nil
    let codeVerifier = Self.randomCodeVerifier()
    let attempt = attemptState.begin(
      provider: provider,
      codeVerifier: codeVerifier,
      codeChallenge: Self.codeChallenge(for: codeVerifier),
      authAttempt: authAttempt
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
      _ = Auth.shared.cancelLoginAttempt(authAttempt)
      if !(error is CancellationError) {
        log.error("Failed to start provider sign-in", error: error)
        errorMessage = Self.userFacingMessage(for: error)
      }
      throw error
    }
  }

  public func prepareNativeAppleAuthorization() async throws -> NativeAppleAuthorizationRequest {
    let authAttempt = try await Auth.shared.beginLoginAttempt()
    completion = nil
    errorMessage = nil
    nativeAppleInviteRequest = nil
    nativeAppleInvite = nil
    let generation = attemptState.beginNativePreparation(authAttempt: authAttempt)
    let codeVerifier = Self.randomCodeVerifier()
    let codeChallenge = Self.codeChallenge(for: codeVerifier)

    do {
      let result = try await ApiClient.shared.startNativeAppleAuth(codeChallenge: codeChallenge)
      guard attemptState.finishNativePreparation(
        generation: generation,
        codeVerifier: codeVerifier,
        codeChallenge: codeChallenge,
        state: result.state
      ) != nil else { throw CancellationError() }
      return NativeAppleAuthorizationRequest(state: result.state, nonce: result.nonce)
    } catch {
      guard attemptState.isCurrentNativePreparation(generation: generation) else { throw error }
      attemptState.cancel()
      _ = Auth.shared.cancelLoginAttempt(authAttempt)
      if !(error is CancellationError) {
        log.error("Failed to prepare native Apple sign-in", error: error)
        errorMessage = Self.userFacingMessage(for: error)
      }
      throw error
    }
  }

  @discardableResult
  public func completeNativeAppleAuthorization(
    state: String?,
    authorizationCode: String?,
    identityToken: String?,
    firstName: String?,
    lastName: String?
  ) async -> Bool {
    guard
      let state,
      let authorizationCode,
      let identityToken,
      let attempt = attemptState.pending,
      attempt.provider == .apple,
      attempt.nativeAppleState == state,
      !isRedeeming
    else {
      errorMessage = String(localized: "Apple Sign-In could not be verified. Please try again.")
      return false
    }

    isRedeeming = true
    redeemingGeneration = attempt.generation
    redeemingAuthAttempt = attempt.authAttempt
    errorMessage = nil
    var serverAcceptedProfile = false
    defer {
      if redeemingGeneration == attempt.generation {
        redeemingGeneration = nil
        redeemingAuthAttempt = nil
        isRedeeming = false
      }
    }
    do {
      let outcome = try await ApiClient.shared.completeNativeAppleAuth(
        state: state,
        authorizationCode: authorizationCode,
        identityToken: identityToken,
        firstName: firstName,
        lastName: lastName
      )
      guard redeemingGeneration == attempt.generation else { return false }
      switch outcome.kind {
      case .complete:
        guard let ticket = outcome.ticket else { throw APIError.invalidResponse }
        serverAcceptedProfile = true
        attemptState.cancel(generation: attempt.generation)
        try await redeemProviderAuth(ticket: ticket, attempt: attempt)
      case .inviteRequired:
        guard let attemptId = outcome.attemptId, let continuation = outcome.continuation else {
          throw APIError.invalidResponse
        }
        serverAcceptedProfile = true
        nativeAppleInvite = (attemptId, continuation)
        nativeAppleInviteRequest = NativeAppleInviteRequest(id: UUID())
      }
      return serverAcceptedProfile
    } catch {
      guard redeemingGeneration == attempt.generation else { return serverAcceptedProfile }
      attemptState.cancel(generation: attempt.generation)
      log.error("Failed to complete native Apple sign-in", error: error)
      errorMessage = Self.userFacingMessage(for: error)
      return serverAcceptedProfile
    }
  }

  public func continueNativeAppleAuthorization(inviteCode: String) async {
    guard
      let invite = nativeAppleInvite,
      let attempt = attemptState.pending,
      attempt.provider == .apple,
      !isRedeeming
    else {
      errorMessage = String(localized: "Apple Sign-In expired. Please try again.")
      return
    }
    isRedeeming = true
    redeemingGeneration = attempt.generation
    redeemingAuthAttempt = attempt.authAttempt
    errorMessage = nil
    defer {
      if redeemingGeneration == attempt.generation {
        redeemingGeneration = nil
        redeemingAuthAttempt = nil
        isRedeeming = false
      }
    }
    do {
      let result = try await ApiClient.shared.continueNativeAppleAuth(
        attemptId: invite.attemptId,
        continuation: invite.continuation,
        inviteCode: inviteCode
      )
      guard redeemingGeneration == attempt.generation else { return }
      attemptState.cancel(generation: attempt.generation)
      nativeAppleInvite = nil
      nativeAppleInviteRequest = nil
      try await redeemProviderAuth(ticket: result.ticket, attempt: attempt)
    } catch {
      guard redeemingGeneration == attempt.generation else { return }
      log.error("Failed to continue native Apple sign-in", error: error)
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  public func recordNativeAppleAuthorizationFailure(_ error: Error) {
    let authAttempt = attemptState.pending?.authAttempt ?? attemptState.nativePreparationAuthAttempt
    attemptState.cancel()
    if let authAttempt { _ = Auth.shared.cancelLoginAttempt(authAttempt) }
    log.error("Native Apple authorization failed", error: error)
    errorMessage = Self.userFacingMessage(for: error)
  }

  public func cancelNativeAppleAuthorization() {
    let authAttempt = attemptState.pending?.authAttempt ?? attemptState.nativePreparationAuthAttempt
    attemptState.cancel()
    if let authAttempt { _ = Auth.shared.cancelLoginAttempt(authAttempt) }
    nativeAppleInvite = nil
    nativeAppleInviteRequest = nil
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
      if let authAttempt = attempt.authAttempt { _ = Auth.shared.cancelLoginAttempt(authAttempt) }
      errorMessage = callbackError == "cancelled"
        ? String(localized: "Sign-in was cancelled. No changes were made.")
        : String(localized: "Inline could not finish signing you in. Please try again.")
      return
    }
    guard let ticket = queryItems?.first(where: { $0.name == "ticket" })?.value,
      !ticket.isEmpty
    else {
      attemptState.cancel(codeChallenge: callbackChallenge)
      if let authAttempt = attempt.authAttempt { _ = Auth.shared.cancelLoginAttempt(authAttempt) }
      errorMessage = String(localized: "Sign-in could not finish. Return to Inline and try again.")
      return
    }
    guard attemptState.take(codeChallenge: callbackChallenge) != nil else { return }

    isRedeeming = true
    redeemingGeneration = attempt.generation
    redeemingAuthAttempt = attempt.authAttempt
    errorMessage = nil
    defer {
      if redeemingGeneration == attempt.generation {
        redeemingGeneration = nil
        redeemingAuthAttempt = nil
        isRedeeming = false
      }
    }
    do {
      try await redeemProviderAuth(ticket: ticket, attempt: attempt)
    } catch {
      guard redeemingGeneration == attempt.generation else { return }
      if let authAttempt = attempt.authAttempt { _ = Auth.shared.cancelLoginAttempt(authAttempt) }
      log.error("Failed to redeem provider sign-in", error: error)
      errorMessage = Self.userFacingMessage(for: error)
    }
  }

  public func recordBrowserOpenFailure(_ error: Error, for url: URL) {
    let challenge = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first(where: { $0.name == "code_challenge" })?.value
    guard let challenge, let attempt = attemptState.matching(codeChallenge: challenge) else { return }
    log.error("Failed to open provider sign-in", error: error)
    attemptState.cancel(codeChallenge: challenge)
    if let authAttempt = attempt.authAttempt {
      _ = Auth.shared.cancelLoginAttempt(authAttempt)
    }
    errorMessage = Self.userFacingMessage(for: error)
  }

  public func consumeCompletion(id: UUID) -> ProviderSignInCompletion? {
    guard completion?.id == id else { return nil }
    defer { completion = nil }
    return completion
  }

  public func consumeNativeAppleInviteRequest(id: UUID) -> NativeAppleInviteRequest? {
    guard nativeAppleInviteRequest?.id == id else { return nil }
    defer { nativeAppleInviteRequest = nil }
    return NativeAppleInviteRequest(id: id)
  }

  public func clearError() {
    errorMessage = nil
  }

  public func cancelPendingAttempt() {
    let attempts = [
      attemptState.pending?.authAttempt,
      attemptState.nativePreparationAuthAttempt,
      redeemingAuthAttempt,
    ].compactMap { $0 }
    attemptState.cancel()
    redeemingGeneration = nil
    redeemingAuthAttempt = nil
    isRedeeming = false
    nativeAppleInvite = nil
    nativeAppleInviteRequest = nil
    for attempt in attempts {
      _ = Auth.shared.cancelLoginAttempt(attempt)
    }
  }

  private func redeemProviderAuth(
    ticket: String,
    attempt: ProviderSignInPendingAttempt
  ) async throws {
    guard let authAttempt = attempt.authAttempt else {
      throw AuthStorageError.loginSuperseded
    }
    var redeemedToken: String?
    var committedLocally = false
    do {
      try await Auth.shared.validateLoginAttempt(authAttempt)
      let result = try await ApiClient.shared.redeemProviderAuth(
        ticket: ticket,
        codeVerifier: attempt.codeVerifier
      )
      redeemedToken = result.token
      let commit = try await LoginStatePreparation.commit(
        loginAttempt: authAttempt,
        targetUserID: result.userId,
        persistCredentials: {
          try await Auth.shared.saveCredentials(
            token: result.token,
            userId: result.userId,
            loginAttempt: authAttempt
          )
        }
      ) { db in
        try result.user.saveFull(db)
      }
      committedLocally = true
      // The DB/authority commit is the linearization point. A view disappearing after it may
      // cancel UI ownership, but it must not suppress the completion that routes the committed
      // account out of onboarding. Likewise, a newer login attempt may not reinterpret this
      // completed server authority as a failed redemption and revoke it remotely.
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
        userCreatedAt: Date(timeIntervalSince1970: TimeInterval(result.user.date)),
        accountMutationToken: commit.accountMutationToken
      )
    } catch {
      if let redeemedToken, committedLocally == false {
        _ = try? await ApiClient.shared.logout(bearerToken: redeemedToken)
      }
      throw error
    }
  }

  private static func userFacingMessage(for error: Error) -> String {
    switch error {
    case APIError.rateLimited:
      String(localized: "Too many sign-in attempts. Wait a moment and try again.")
    case APIError.networkError:
      String(localized: "Inline could not connect. Check your connection and try again.")
    case let APIError.error(_, _, description):
      description ?? String(localized: "Inline could not finish signing you in. Please try again.")
    case let error as AuthStorageError:
      error.localizedDescription
    case let error as LoginStatePreparationError:
      error.localizedDescription
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
