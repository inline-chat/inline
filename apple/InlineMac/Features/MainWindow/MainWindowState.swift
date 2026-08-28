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
    case .authenticated, .authenticatedV3:
      return .main
    case .unauthenticated, .reauthRequired:
      return .onboarding
    case .hydrating, .locked, .loggingOut:
      return .loading
    }
  }
}

class MainWindowViewModel: ObservableObject {
  @Published var topLevelRoute: TopLevelRoute
  private(set) var onboardingInitialRoute: OnboardingRoute = .welcome

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
    onboardingInitialRoute = .welcome
    topLevelRoute = Auth.shared.getHasPendingAccountTransition() ? .loading : route
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
          guard !Task.isCancelled,
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
