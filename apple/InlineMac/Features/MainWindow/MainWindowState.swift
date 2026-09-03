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
      return .main
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
  case accountRecovery = "account_recovery"
  case presentation

  static func current(status: AuthStatus, hasPendingAccountTransition: Bool) -> Self {
    guard !hasPendingAccountTransition else { return .accountRecovery }
    switch status {
    case .hydrating: return .credentials
    case .locked: return .keychain
    case .loggingOut: return .accountRecovery
    case .authenticated, .authenticatedV3, .unauthenticated, .reauthRequired: return .database
    }
  }

  var allowsRetry: Bool {
    self == .credentials || self == .keychain || self == .database
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

  init() {
    topLevelRoute = TopLevelRoute.initial(
      for: Auth.shared.getStatus(),
      persistentStorage: AppDatabase.shared.isPersistent
    )
    startupLoadingReason = Self.currentStartupLoadingReason()

    // `Auth.status` is main actor-isolated; set up the subscription on the main actor.
    Task { @MainActor [weak self] in
      guard let self else { return }
      Auth.shared.$status
        .receive(on: DispatchQueue.main)
        .sink { [weak self] status in
          self?.handle(status: status)
        }
        .store(in: &cancellables)
    }
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
      _ = await AppDatabase.promoteSharedToPersistentIfPossible()
      guard !Task.isCancelled, AppDatabase.shared.isPersistent else { return }
      switch Auth.shared.getStatus() {
      case .authenticated, .authenticatedV3:
        guard await Api.admitPersistentStorage() else { return }
        self?.topLevelRoute = .main
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
      hasPendingAccountTransition: Auth.shared.getHasPendingAccountTransition()
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
    topLevelRoute = Auth.shared.getHasPendingAccountTransition()
      || (route != .loading && AppDatabase.shared.isPersistent == false)
      ? .loading
      : route
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
        break

      case .authenticated, .authenticatedV3:
        transitionTask?.cancel()
        transitionTask = Task { @MainActor [weak self] in
          _ = await AppDatabase.promoteSharedToPersistentIfPossible()
          let realtimeAdmitted = await Api.admitPersistentStorage()
          guard !Task.isCancelled,
                AppDatabase.shared.isPersistent,
                realtimeAdmitted,
                Auth.shared.getHasPendingAccountTransition() == false,
                Auth.shared.getStatus().isAuthenticated
          else { return }
          self?.topLevelRoute = .main
        }

      case .unauthenticated, .reauthRequired:
        transitionTask?.cancel()
        transitionTask = Task { @MainActor [weak self] in
          _ = await AppDatabase.promoteSharedToPersistentIfPossible()
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
      transitionTask?.cancel()
      transitionTask = nil
      if case .loggingOut = status {
        topLevelRoute = .loading
      }
      // Otherwise onboarding drives navigation to `.main` after login/profile completion.
      break
    }
  }
}
