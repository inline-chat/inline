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
    self.route = route
  }

  private static func initialRoute(for status: AuthStatus) -> MainRoutes {
    switch status {
    case .authenticated:
      return .main
    case .hydrating, .locked:
      return .loading
    case .unauthenticated, .reauthRequired:
      return .onboarding
    }
  }

  private func handle(status: AuthStatus) {
    // Only auto-route while we're still resolving early-launch / protected-data timing issues.
    switch route {
    case .loading:
      switch status {
      case .authenticated:
        transitionTask?.cancel()
        transitionTask = Task { @MainActor [weak self] in
          // Ensure `AppDatabase.shared` isn't stuck on an in-memory fallback from pre-unlock startup.
          _ = await AppDatabase.promoteSharedToPersistentIfPossible()
          guard !Task.isCancelled else { return }
          self?.route = .main
        }
      case .unauthenticated, .reauthRequired:
        transitionTask?.cancel()
        transitionTask = Task { @MainActor [weak self] in
          _ = await AppDatabase.promoteSharedToPersistentIfPossible()
          guard !Task.isCancelled else { return }
          self?.route = .onboarding
        }
      case .hydrating, .locked:
        break
      }

    case .main:
      switch status {
      case .unauthenticated, .reauthRequired:
        transitionTask?.cancel()
        transitionTask = nil
        route = .onboarding
      case .authenticated, .hydrating, .locked:
        break
      }

    case .onboarding:
      transitionTask?.cancel()
      transitionTask = nil
      // Do not auto-switch to `.main` on login: onboarding may still need to finish profile/setup.
      break
    }
  }
}
