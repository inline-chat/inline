import SwiftUI

struct Onboarding: View {
  @EnvironmentObject private var windowViewModel: MainWindowViewModel
  @StateObject private var viewModel: OnboardingViewModel
  @State private var profileSetup = OnboardingProfileSetupModel()

  let allowsBackgroundWindowDrag: Bool

  init(
    allowsBackgroundWindowDrag: Bool = false,
    initialRoute: OnboardingRoute = .welcome
  ) {
    self.allowsBackgroundWindowDrag = allowsBackgroundWindowDrag
    _viewModel = StateObject(wrappedValue: OnboardingViewModel(initialRoute: initialRoute))
  }

  private let forwardTransition: AnyTransition = .asymmetric(
    insertion: .push(from: .trailing),
    removal: .push(from: .trailing)
  )

  private let backwardTransition: AnyTransition = .asymmetric(
    insertion: .push(from: .leading),
    removal: .push(from: .leading)
  )

  private var routeTransition: AnyTransition {
    if viewModel.goingBack {
      backwardTransition
    } else {
      forwardTransition
    }
  }

  var body: some View {
    ZStack {
      background

      switch viewModel.path.last {
      case .welcome:
        OnboardingWelcome().transition(routeTransition)
      case .getStarted:
        OnboardingGetStarted().transition(routeTransition)
      case .enterPhone:
        OnboardingEnterPhone().transition(routeTransition)
      case .enterEmail:
        OnboardingEnterEmail().transition(routeTransition)
      case .enterCode:
        OnboardingEnterCode().transition(routeTransition)
      case .inviteCode:
        OnboardingInviteCode().transition(routeTransition)
      case .profile:
        OnboardingProfile().transition(routeTransition)
      case .username:
        OnboardingUsername().transition(routeTransition)
      case .appearance:
        OnboardingAppearance().transition(routeTransition)
      case .none:
        OnboardingWelcome().transition(routeTransition)
      }
    }
    .animation(.smoothSnappy, value: viewModel.path)
    .toolbar(content: {
      if viewModel.canGoBack {
        ToolbarItem(placement: .navigation) {
          Button {
            viewModel.goBack()
          } label: {
            Image(systemName: "chevron.left")
          }
        }
      } else {
        // Hack to show toolbar in first screen to avoid a jump
        // When going back from an inner screen

        ToolbarItem(placement: .navigation) {
          Text("")
        }
      }
    })
    .environmentObject(viewModel)
    .environment(profileSetup)
    .task {
      viewModel.setMainWindowViewModel(windowViewModel)
    }
  }

  @ViewBuilder
  private var background: some View {
    if allowsBackgroundWindowDrag {
      backgroundSurface
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents(true)
    } else {
      backgroundSurface
    }
  }

  private var backgroundSurface: some View {
    VisualEffectView(material: .popover, blendingMode: .behindWindow)
      .overlay {
        LinearGradient(
          colors: [
            .white.opacity(0.0),
            .white.opacity(0.05),
            .white.opacity(0.0),
          ],
          startPoint: .topTrailing,
          endPoint: .bottomLeading,
        )
      }
      .ignoresSafeArea(edges: .all)
  }
}

enum OnboardingRoute {
  case welcome
  case getStarted
  case enterPhone
  case enterEmail
  case enterCode
  case inviteCode
  case profile
  case username
  case appearance
}

@MainActor
final class OnboardingViewModel: ObservableObject {
  @Published fileprivate var path: [OnboardingRoute]

  // Email entered in the onboarding
  @Published var email: String = ""
  @Published var emailChallengeToken: String?
  @Published var phoneNumber: String = ""
  @Published var inviteCode: String = ""

  // nil = server provided no data, true = login, false = sign up
  @Published var existingUser: Bool?

  // Becomes berifly true when we're navigating
  @Published var navigatingToMainView = false
  @Published var goingBack = false

  var canGoBack: Bool {
    path.count > 1
  }

  func navigate(to route: OnboardingRoute) {
    DispatchQueue.main.async {
      self.path.append(route)
    }
  }

  // Special navigate that decides next step after user is verified and logged in
  // i.e. we have token and current user id, should we open profile or main view?
  func navigateAfterLogin(pendingSetup: Bool) {
    if pendingSetup {
      navigate(to: .profile)
    } else {
      navigatingToMainView = true
      mainWindowViewModel?.navigate(.main)
    }
  }

  func finishSetup(firstName: String?) {
    navigatingToMainView = true
    if existingUser == false {
      mainWindowViewModel?.navigateAfterSignup(firstName: firstName)
    } else {
      mainWindowViewModel?.navigate(.main)
    }
  }

  func goBack() {
    DispatchQueue.main.async {
      self.goingBack = true
      DispatchQueue.main.async {
        self.path.removeLast()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          self.goingBack = false
        }
      }
    }
  }

  weak var mainWindowViewModel: MainWindowViewModel?

  init(initialRoute: OnboardingRoute = .welcome) {
    path = [initialRoute]
  }

  func setMainWindowViewModel(_ mvm: MainWindowViewModel) {
    mainWindowViewModel = mvm
  }
}

#Preview {
  Onboarding()
    .environmentObject(MainWindowViewModel())
    .environmentObject(OnboardingViewModel())
    .frame(width: 900, height: 600)
}
