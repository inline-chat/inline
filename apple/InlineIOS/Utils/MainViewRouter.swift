import Auth
import Foundation
import InlineKit
import Logger
import SwiftUI
import Combine

public enum MainRoutes {
  case loading
  case main
  case onboarding
}

public class MainViewRouter: ObservableObject {
  @Published var route: MainRoutes
  private var cancellables: Set<AnyCancellable> = []
  private var transitionTask: Task<Void, Never>?

  init() {
    route = Self.initialRoute(for: Auth.shared.getStatus())

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

  public func setRoute(route: MainRoutes) {
    self.route = Auth.shared.getHasPendingAccountTransition() ? .loading : route
  }

  private static func initialRoute(for status: AuthStatus) -> MainRoutes {
    switch status {
    case .authenticated, .authenticatedV3:
      return .main
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
          guard !Task.isCancelled,
                Auth.shared.getHasPendingAccountTransition() == false,
                Auth.shared.getStatus().isAuthenticated
          else { return }
          self?.route = .main
        }
      case .unauthenticated, .reauthRequired:
        transitionTask?.cancel()
        transitionTask = Task { @MainActor [weak self] in
          _ = await AppDatabase.promoteSharedToPersistentIfPossible()
          guard !Task.isCancelled,
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
        break
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
      transitionTask?.cancel()
      transitionTask = nil
      if case .loggingOut = status {
        route = .loading
      }
      // Do not auto-switch to `.main` on login: onboarding may still need to finish profile/setup.
      break
    }
  }
}
