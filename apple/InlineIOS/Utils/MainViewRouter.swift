import Auth
import Combine
import Foundation
import InlineKit
import Sentry
import SwiftUI
import UIKit

public enum MainRoutes: Equatable {
  case loading
  case main
  case onboarding
}

@MainActor
public class MainViewRouter: ObservableObject {
  let onboardingNavigation = OnboardingNavigation()
  @Published var route: MainRoutes
  @Published private(set) var isRetryingStartup = false
  private var cancellables: Set<AnyCancellable> = []
  private var transitionTask: Task<Void, Never>?
  private var startupRetryTask: Task<Void, Never>?

  init() {
    route = Self.initialRoute(
      for: Auth.shared.getStatus(),
      persistentStorage: AppDatabase.shared.isPersistent
    )

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
    transitionTask?.cancel()
    startupRetryTask?.cancel()
  }

  public func setRoute(route: MainRoutes) {
    transitionTask?.cancel()
    transitionTask = nil
    guard route == .main else {
      self.route = Auth.shared.getHasPendingAccountTransition()
        || (route != .loading && AppDatabase.shared.isPersistent == false)
        ? .loading
        : route
      return
    }

    // Keep onboarding mounted while admitting persistent storage and realtime. The transition to
    // Main is then a single visible swap; only an actual admission failure enters startup recovery.
    guard Auth.shared.getHasPendingAccountTransition() == false else {
      self.route = .loading
      return
    }
    transitionTask = Task { @MainActor [weak self] in
      _ = await AppDatabase.promoteSharedToPersistentIfPossible()
      let realtimeAdmitted = await Api.admitPersistentStorage()
      guard !Task.isCancelled else { return }
      guard AppDatabase.shared.isPersistent,
            realtimeAdmitted,
            Auth.shared.getHasPendingAccountTransition() == false,
            Auth.shared.getStatus().isAuthenticated
      else {
        self?.route = .loading
        return
      }
      await self?.resolveAuthenticatedRoute()
    }
  }

  @MainActor
  func retryStartup() {
    guard route == .loading, startupRetryTask == nil,
          Auth.shared.getHasPendingAccountTransition() == false
    else { return }
    isRetryingStartup = true
    startupRetryTask = Task { @MainActor [weak self] in
      defer {
        self?.isRetryingStartup = false
        self?.startupRetryTask = nil
      }
      await Auth.shared.refreshFromStorage()
      guard !Task.isCancelled,
            Auth.shared.getHasPendingAccountTransition() == false
      else { return }
      _ = await AppDatabase.promoteSharedToPersistentIfPossible()
      guard !Task.isCancelled, AppDatabase.shared.isPersistent else { return }
      switch Auth.shared.getStatus() {
      case .authenticated, .authenticatedV3:
        guard await Api.admitPersistentStorage() else { return }
        await self?.resolveAuthenticatedRoute()
      case .unauthenticated, .reauthRequired:
        self?.route = .onboarding
      case .hydrating, .locked, .loggingOut:
        return
      }
    }
  }

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
      if let userID {
        onboardingNavigation.prepareProfileDraft(for: userID)
        onboardingNavigation.path = [.profile(userId: userID)]
        route = .onboarding
      } else {
        route = .main
      }
    } catch {
      guard !Task.isCancelled,
            (try? Auth.shared.handle.validateAccountMutation(account)) != nil
      else { return }
      route = .loading
    }
  }

  private static func initialRoute(for status: AuthStatus, persistentStorage: Bool) -> MainRoutes {
    guard persistentStorage else { return .loading }
    switch status {
    case .authenticated, .authenticatedV3:
      return .loading
    case .hydrating, .locked, .loggingOut:
      return .loading
    case .unauthenticated, .reauthRequired:
      return .onboarding
    }
  }

  private func handle(status: AuthStatus) {
    if Auth.shared.getHasPendingAccountTransition() {
      transitionTask?.cancel()
      transitionTask = nil
      route = .loading
      return
    }
    // Only auto-route while we're still resolving early-launch / protected-data timing issues.
    switch route {
    case .loading:
      switch status {
      case .authenticated, .authenticatedV3:
        transitionTask?.cancel()
        transitionTask = Task { @MainActor [weak self] in
          // Ensure `AppDatabase.shared` isn't stuck on an in-memory fallback from pre-unlock startup.
          _ = await AppDatabase.promoteSharedToPersistentIfPossible()
          let realtimeAdmitted = await Api.admitPersistentStorage()
          guard !Task.isCancelled,
                AppDatabase.shared.isPersistent,
                realtimeAdmitted,
                Auth.shared.getHasPendingAccountTransition() == false,
                Auth.shared.getStatus().isAuthenticated
          else { return }
          await self?.resolveAuthenticatedRoute()
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
          self?.route = .onboarding
        }
      case .hydrating, .locked, .loggingOut:
        transitionTask?.cancel()
        transitionTask = nil
      }

    case .main:
      switch status {
      case .unauthenticated, .reauthRequired:
        transitionTask?.cancel()
        transitionTask = nil
        route = .onboarding
      case .loggingOut:
        transitionTask?.cancel()
        transitionTask = nil
        route = .loading
      case .authenticated, .authenticatedV3, .hydrating, .locked:
        break
      }

    case .onboarding:
      switch status {
      case .loggingOut:
        transitionTask?.cancel()
        transitionTask = nil
        route = .loading
      case .unauthenticated, .reauthRequired:
        transitionTask?.cancel()
        transitionTask = nil
      case .authenticated, .authenticatedV3, .hydrating, .locked:
        break
      }
      // Do not auto-switch to `.main` on login: onboarding may still need to finish profile/setup.
    }
  }
}

struct IOSStartupLoadingView: View {
  @ObservedObject var router: MainViewRouter
  @State private var showsRecovery = false
  @State private var didReportRecovery = false

  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      if showsRecovery {
        Text("Inline is taking longer to open")
          .font(.headline)
        Text(explanation)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 360)
        if Auth.shared.getHasPendingAccountTransition() == false {
          Button("Try Again") {
            router.retryStartup()
          }
          .buttonStyle(.borderedProminent)
          .disabled(router.isRetryingStartup)
          .padding(.top, 4)
        }
      } else {
        Text("Loading…")
          .font(.headline)
          .foregroundStyle(.secondary)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(uiColor: .systemBackground))
    .task {
      showsRecovery = false
      do {
        try await Task.sleep(for: .seconds(5))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      showsRecovery = true
      reportStartupDelayIfNeeded()
    }
  }

  private func reportStartupDelayIfNeeded() {
    guard !didReportRecovery, SentrySDK.isEnabled else { return }
    didReportRecovery = true

    let storageState: String
    let failureReason: String
    switch AppDatabase.shared.persistentStoreAdmission {
    case .ready:
      storageState = "ready"
      failureReason = "none"
    case .retryable(let failure):
      storageState = "retryable"
      failureReason = failure.reason.rawValue
    case .terminal(let failure):
      storageState = "terminal"
      failureReason = failure.reason.rawValue
    }

    let authState: String = switch Auth.shared.getStatus() {
    case .hydrating: "hydrating"
    case .locked: "locked"
    case .loggingOut: "logging_out"
    case .authenticated: "authenticated_v2"
    case .authenticatedV3: "authenticated_v3"
    case .unauthenticated: "unauthenticated"
    case .reauthRequired: "reauth_required"
    }

    _ = SentrySDK.capture(message: "ios_startup_delayed") { scope in
      scope.setLevel(.error)
      scope.setFingerprint(["ios-startup-delayed", storageState, failureReason])
      scope.clearBreadcrumbs()
      scope.setTag(value: "ios_startup_delayed", key: "event")
      scope.setTag(value: "IOSStartup", key: "scope")
      scope.setTag(value: authState, key: "startup.auth_state")
      scope.setTag(value: storageState, key: "startup.storage")
      scope.setTag(value: failureReason, key: "startup.storage_failure_reason")
      scope.setTag(
        value: Auth.shared.getHasPendingAccountTransition() ? "true" : "false",
        key: "startup.account_recovery"
      )
      scope.setExtra(value: 5, key: "startup.elapsed_seconds")
    }
  }

  private var explanation: LocalizedStringResource {
    if Auth.shared.getHasPendingAccountTransition() {
      return "Inline is finishing account recovery. Reopen Inline if this continues."
    }
    switch AppDatabase.shared.persistentStoreAdmission {
    case .ready:
      return "Inline is finishing opening your account."
    case .retryable(let failure):
      if failure.reason == .keychainLocked {
        return "Unlock this device, then try opening your saved account again."
      }
      return "Inline is still opening your local data. Your saved data won’t be reset."
    case .terminal:
      return "Inline couldn’t open its local data. Your saved data won’t be reset automatically."
    }
  }
}
