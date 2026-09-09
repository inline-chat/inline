import Auth
import Combine
import Foundation
import InlineKit
import Logger
import Sentry

enum TopLevelRoute: Equatable {
  case loading
  case onboarding
  case main

  static func initial(for status: AuthStatus, persistentStorage: Bool) -> TopLevelRoute {
    guard persistentStorage else { return .loading }
    switch status {
    case .authenticated, .authenticatedV3:
      return .loading
    case .unauthenticated, .reauthRequired:
      return .onboarding
    case .hydrating, .locked, .loggingOut:
      return .loading
    }
  }
}

enum StartupLoadingReason: String, Sendable {
  case credentials
  case keychain
  case database
  case profile
  case accountRecovery = "account_recovery"
  case presentation

  static func current(status: AuthStatus, hasPendingAccountTransition: Bool, persistentStorage: Bool) -> Self {
    guard !hasPendingAccountTransition else { return .accountRecovery }
    switch status {
    case .hydrating: return .credentials
    case .locked: return .keychain
    case .loggingOut: return .accountRecovery
    case .authenticated, .authenticatedV3: return persistentStorage ? .profile : .database
    case .unauthenticated, .reauthRequired: return .database
    }
  }

  var allowsRetry: Bool {
    self == .credentials || self == .keychain || self == .database || self == .profile
  }
}

/// A fixed snapshot shared by the disclosure, clipboard, and Sentry. Never stringify AuthStatus:
/// its associated values include credentials. Keep this projection explicitly allowlisted.
struct StartupLoadingDiagnostics: Sendable {
  let reason: StartupLoadingReason
  let authState: String
  let persistentStorage: Bool
  let storageAdmission: String
  let storageFailureReason: String
  let pendingAccountTransition: Bool
  let elapsedSeconds: Int
  let appVersion: String
  let appBuild: String

  static func authStateName(_ status: AuthStatus) -> String {
    switch status {
    case .hydrating: "hydrating"
    case .locked: "locked"
    case .loggingOut: "logging_out"
    case .authenticated: "authenticated_v2"
    case .authenticatedV3: "authenticated_v3"
    case .unauthenticated: "unauthenticated"
    case .reauthRequired: "reauth_required"
    }
  }

  var text: String {
    [
      "Diagnostic: mac_startup_delayed",
      "Startup phase: \(reason.rawValue)",
      "Authentication: \(authState)",
      "Local storage: \(persistentStorage ? "persistent" : "temporary")",
      "Storage admission: \(storageAdmission)",
      "Storage failure: \(storageFailureReason)",
      "Account recovery pending: \(pendingAccountTransition ? "yes" : "no")",
      "Snapshot captured after: \(elapsedSeconds)s",
      "App: \(appVersion) (\(appBuild))",
    ].joined(separator: "\n")
  }

  func report() {
    // Capture can copy SDK scope synchronously; keep it off the UI actor. This one-shot
    // report should outlive the loading view, without starting another startup operation.
    Task.detached(priority: .utility) {
      guard SentrySDK.isEnabled else { return }
      _ = SentrySDK.capture(message: "mac_startup_delayed") { scope in
        scope.setLevel(.error)
        scope.setFingerprint(["mac-startup-delayed", reason.rawValue])
        scope.clearBreadcrumbs()
        scope.setTag(value: "mac_startup_delayed", key: "event")
        scope.setTag(value: "MacStartup", key: "scope")
        scope.setTag(value: reason.rawValue, key: "startup.phase")
        scope.setTag(value: authState, key: "startup.auth_state")
        scope.setTag(value: persistentStorage ? "persistent" : "temporary", key: "startup.storage")
        scope.setTag(value: storageAdmission, key: "startup.storage_admission")
        scope.setTag(value: storageFailureReason, key: "startup.storage_failure_reason")
        scope.setTag(value: pendingAccountTransition ? "true" : "false", key: "startup.account_recovery")
        scope.setExtra(value: elapsedSeconds, key: "startup.elapsed_seconds")
        scope.setTag(value: appVersion, key: "app_version")
        scope.setTag(value: appBuild, key: "app_build")
      }
    }
  }
}

class MainWindowViewModel: ObservableObject {
  @Published var topLevelRoute: TopLevelRoute {
    didSet {
      if topLevelRoute != .loading { startupLoadingDiagnostics = nil }
    }
  }
  @Published private(set) var startupLoadingReason: StartupLoadingReason
  @Published private(set) var startupLoadingDiagnostics: StartupLoadingDiagnostics?
  @Published private(set) var isRetryingStartup = false
  private(set) var onboardingInitialRoute: OnboardingRoute = .welcome

  private var cancellables: Set<AnyCancellable> = []
  private var transitionTask: Task<Void, Never>?
  private var startupRetryTask: Task<Void, Never>?

  @MainActor init() {
    topLevelRoute = TopLevelRoute.initial(
      for: Auth.shared.getStatus(),
      persistentStorage: AppDatabase.shared.isPersistent
    )
    startupLoadingReason = Self.currentStartupLoadingReason()

    // Seed from the ready credential cache instead of waiting for its initial UI replay.
    // Keep subsequent transitions ordered, without another main-queue hop or restarting
    // the local profile read when the initial authenticated status is replayed.
    Auth.shared.$status
      .dropFirst()
      .prepend(Auth.shared.getStatus())
      .removeDuplicates()
      .sink { [weak self] status in
        self?.handle(status: status)
      }
      .store(in: &cancellables)
  }

  deinit {
    startupRetryTask?.cancel()
    transitionTask?.cancel()
  }

  @MainActor func reportStartupLoadingDelay(elapsedSeconds: Int) {
    guard startupLoadingDiagnostics == nil else { return }
    let reason = topLevelRoute == .loading ? Self.currentStartupLoadingReason() : .presentation
    let storage = Self.currentStorageDiagnostics()
    startupLoadingReason = reason
    let diagnostics = StartupLoadingDiagnostics(
      reason: reason,
      authState: StartupLoadingDiagnostics.authStateName(Auth.shared.getStatus()),
      persistentStorage: AppDatabase.shared.isPersistent,
      storageAdmission: storage.admission,
      storageFailureReason: storage.failureReason,
      pendingAccountTransition: Auth.shared.getHasPendingAccountTransition(),
      elapsedSeconds: max(0, elapsedSeconds),
      appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
      appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    )
    startupLoadingDiagnostics = diagnostics
    Log.scoped("MacStartup").warning("Startup loading exceeded the recovery deadline; phase=\(reason.rawValue)")
    diagnostics.report()
  }

  @MainActor func retryStartup() {
    // Read current authority at invocation; the visible explanation can predate an account change.
    guard topLevelRoute == .loading,
          startupRetryTask == nil,
          Self.currentStartupLoadingReason().allowsRetry
    else { return }

    isRetryingStartup = true
    startupRetryTask = Task { @MainActor [weak self] in
      defer {
        self?.isRetryingStartup = false
        self?.startupRetryTask = nil
      }
      guard !Task.isCancelled else { return }
      let reason = Self.currentStartupLoadingReason()
      if reason == .credentials || reason == .keychain {
        // The existing AuthStore serializes Keychain access and publishes the resulting state.
        await Auth.shared.refreshFromStorage()
      }
      guard !Task.isCancelled,
            Auth.shared.getHasPendingAccountTransition() == false
      else { return }
      if !AppDatabase.shared.isPersistent {
        _ = await AppDatabase.promoteSharedToPersistentIfPossible()
      }
      guard !Task.isCancelled, AppDatabase.shared.isPersistent else { return }
      switch Auth.shared.getStatus() {
      case .authenticated, .authenticatedV3:
        await self?.resolveAuthenticatedRoute()
      case .unauthenticated, .reauthRequired:
        self?.topLevelRoute = .onboarding
      case .hydrating, .locked, .loggingOut:
        return
      }
    }
  }

  private static func currentStartupLoadingReason() -> StartupLoadingReason {
    .current(
      status: Auth.shared.getStatus(),
      hasPendingAccountTransition: Auth.shared.getHasPendingAccountTransition(),
      persistentStorage: AppDatabase.shared.isPersistent
    )
  }

  private static func currentStorageDiagnostics() -> (admission: String, failureReason: String) {
    switch AppDatabase.shared.persistentStoreAdmission {
    case .ready:
      ("ready", "none")
    case .retryable(let failure):
      ("retryable", failure.reason.rawValue)
    case .terminal(let failure):
      ("terminal", failure.reason.rawValue)
    }
  }

  func navigate(_ route: TopLevelRoute) {
    transitionTask?.cancel()
    transitionTask = nil
    onboardingInitialRoute = .welcome
    guard route == .main else {
      topLevelRoute = Auth.shared.getHasPendingAccountTransition()
        || (route != .loading && AppDatabase.shared.isPersistent == false)
        ? .loading
        : route
      return
    }

    // Keep onboarding mounted until local storage and profile state choose the destination.
    // Realtime startup must not delay a completed account's cached UI.
    guard Auth.shared.getHasPendingAccountTransition() == false else {
      topLevelRoute = .loading
      return
    }
    transitionTask = Task { @MainActor [weak self] in
      if !AppDatabase.shared.isPersistent {
        _ = await AppDatabase.promoteSharedToPersistentIfPossible()
      }
      guard !Task.isCancelled else { return }
      guard AppDatabase.shared.isPersistent,
            Auth.shared.getHasPendingAccountTransition() == false,
            Auth.shared.getStatus().isAuthenticated
      else {
        self?.topLevelRoute = .loading
        return
      }
      await self?.resolveAuthenticatedRoute()
    }
  }

#if DEBUG || DEBUG_BUILD
  func openOnboardingForDebug() {
    guard Auth.shared.getHasPendingAccountTransition() == false else {
      topLevelRoute = .loading
      return
    }
    if case .loggingOut = Auth.shared.getStatus() {
      topLevelRoute = .loading
      return
    }
    transitionTask?.cancel()
    transitionTask = nil
    onboardingInitialRoute = .profile
    topLevelRoute = .onboarding
  }
#endif

  @MainActor
  private func resolveAuthenticatedRoute() async {
    guard let account = try? Auth.shared.handle.beginAccountMutation() else { return }
    do {
      let userID = try await OnboardingSession.pendingProfileUserID()
      guard !Task.isCancelled,
            Auth.shared.getStatus().isAuthenticated,
            !Auth.shared.getHasPendingAccountTransition()
      else { return }
      guard (try? Auth.shared.handle.validateAccountMutation(account)) != nil else { return }
      onboardingInitialRoute = userID == nil ? .welcome : .profile
      topLevelRoute = userID == nil ? .main : .onboarding
      PerformanceTrace.event("StartupRouteResolved", category: .launch)
      // Publish the locally resolved route before waiting for any realtime owners.
      _ = await Api.admitPersistentStorage()
    } catch {
      guard !Task.isCancelled,
            (try? Auth.shared.handle.validateAccountMutation(account)) != nil
      else { return }
      topLevelRoute = .loading
    }
  }

  private func handle(status: AuthStatus) {
    startupLoadingReason = Self.currentStartupLoadingReason()
    if Auth.shared.getHasPendingAccountTransition() {
      transitionTask?.cancel()
      transitionTask = nil
      topLevelRoute = .loading
      return
    }
    switch topLevelRoute {
    case .loading:
      switch status {
      case .hydrating, .locked, .loggingOut:
        transitionTask?.cancel()
        transitionTask = nil

      case .authenticated, .authenticatedV3:
        transitionTask?.cancel()
        transitionTask = Task { @MainActor [weak self] in
          if !AppDatabase.shared.isPersistent {
            _ = await AppDatabase.promoteSharedToPersistentIfPossible()
          }
          guard !Task.isCancelled,
                AppDatabase.shared.isPersistent,
                Auth.shared.getHasPendingAccountTransition() == false,
                Auth.shared.getStatus().isAuthenticated
          else { return }
          await self?.resolveAuthenticatedRoute()
        }

      case .unauthenticated, .reauthRequired:
        transitionTask?.cancel()
        transitionTask = Task { @MainActor [weak self] in
          if !AppDatabase.shared.isPersistent {
            _ = await AppDatabase.promoteSharedToPersistentIfPossible()
          }
          guard !Task.isCancelled,
                AppDatabase.shared.isPersistent,
                Auth.shared.getHasPendingAccountTransition() == false
          else { return }
          switch Auth.shared.getStatus() {
          case .unauthenticated, .reauthRequired:
            break
          case .authenticated, .authenticatedV3, .hydrating, .locked, .loggingOut:
            return
          }
          self?.topLevelRoute = .onboarding
        }
      }

    case .main:
      // Don't downgrade to onboarding on transient locked states; only on explicit logout.
      switch status {
      case .unauthenticated, .reauthRequired:
        transitionTask?.cancel()
        transitionTask = nil
        topLevelRoute = .onboarding
      case .loggingOut:
        transitionTask?.cancel()
        transitionTask = nil
        topLevelRoute = .loading
      case .authenticated, .authenticatedV3, .hydrating, .locked:
        break
      }

    case .onboarding:
      switch status {
      case .loggingOut:
        transitionTask?.cancel()
        transitionTask = nil
        topLevelRoute = .loading
      case .unauthenticated, .reauthRequired:
        transitionTask?.cancel()
        transitionTask = nil
      case .authenticated, .authenticatedV3, .hydrating, .locked:
        break
      }
      // Otherwise onboarding drives navigation to `.main` after login/profile completion.
    }
  }
}
