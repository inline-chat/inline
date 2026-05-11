import Auth
import Combine
import Foundation
import InlineKit

enum TopLevelRoute {
  case loading
  case onboarding
  case main

  static func initial(for status: AuthStatus) -> TopLevelRoute {
    switch status {
    case .authenticated:
      return .main
    case .unauthenticated, .reauthRequired:
      return .onboarding
    case .hydrating, .locked:
      return .loading
    }
  }
}

class MainWindowViewModel: ObservableObject {
  @Published var topLevelRoute: TopLevelRoute

  private var cancellables: Set<AnyCancellable> = []
  private var transitionTask: Task<Void, Never>?

  init() {
    topLevelRoute = TopLevelRoute.initial(for: Auth.shared.getStatus())

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

  func navigate(_ route: TopLevelRoute) {
    transitionTask?.cancel()
    transitionTask = nil
    topLevelRoute = route
  }

  private func handle(status: AuthStatus) {
    switch topLevelRoute {
    case .loading:
      switch status {
      case .hydrating, .locked:
        break

      case .authenticated:
        transitionTask?.cancel()
        transitionTask = Task { @MainActor [weak self] in
          _ = await AppDatabase.promoteSharedToPersistentIfPossible()
          guard !Task.isCancelled else { return }
          self?.topLevelRoute = .main
        }

      case .unauthenticated, .reauthRequired:
        transitionTask?.cancel()
        transitionTask = Task { @MainActor [weak self] in
          _ = await AppDatabase.promoteSharedToPersistentIfPossible()
          guard !Task.isCancelled else { return }
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
      case .authenticated, .hydrating, .locked:
        break
      }

    case .onboarding:
      // Onboarding drives navigation to `.main` after login/profile completion.
      transitionTask?.cancel()
      transitionTask = nil
      break
    }
  }
}
