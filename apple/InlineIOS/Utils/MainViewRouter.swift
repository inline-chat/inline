import Auth
import Combine
import Foundation
import InlineKit
import Logger
import Sentry
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

    // Keep onboarding mounted until local storage and profile state choose the destination.
    // Realtime startup must not delay a completed account's cached UI.
    guard Auth.shared.getHasPendingAccountTransition() == false else {
      self.route = .loading
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
      if !AppDatabase.shared.isPersistent {
        _ = await AppDatabase.promoteSharedToPersistentIfPossible()
      }
      guard !Task.isCancelled, AppDatabase.shared.isPersistent else { return }
      switch Auth.shared.getStatus() {
      case .authenticated, .authenticatedV3:
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
      PerformanceTrace.event("StartupRouteResolved", category: .launch)
      // Publish the locally resolved route before waiting for any realtime owners.
      _ = await Api.admitPersistentStorage()
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
          // Only pre-unlock/fallback storage needs promotion; normal launches keep their writer.
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
