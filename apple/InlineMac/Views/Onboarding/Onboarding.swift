import SwiftUI

struct Onboarding: View {
  @EnvironmentObject var windowViewModel: MainWindowViewModel
  @StateObject var viewModel = OnboardingViewModel()

  var routeTransition1: AnyTransition = .asymmetric(
    insertion: .push(from: .trailing),
    removal: .push(from: .trailing)
  )

  var routeTransition2: AnyTransition = .asymmetric(
    insertion: .push(from: .leading),
    removal: .push(from: .leading)
  )

  var routeTransition: AnyTransition {
    if viewModel.goingBack {
      routeTransition2
    } else {
      routeTransition1
    }
  }

  var body: some View {
    ZStack {
      switch viewModel.path.last {
        case .welcome:
          OnboardingWelcome().transition(routeTransition)
        case .enterEmail:
          OnboardingEnterEmail().transition(routeTransition)
        case .enterCode:
          OnboardingEnterCode().transition(routeTransition)
        case .profile:
          OnboardingProfile().transition(routeTransition)
        case .none:
          OnboardingWelcome().transition(routeTransition)
      }
    }
//    .animation(.snappy.speed(1.5), value: self.viewModel.path)
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
    .task {
      viewModel.setMainWindowViewModel(windowViewModel)
    }
  }
}

enum OnboardingRoute {
  case welcome
  case enterEmail
  case enterCode
  case profile
}

@MainActor
class OnboardingViewModel: ObservableObject {
  //    @Published fileprivate var path: NavigationPath = .init()
  @Published fileprivate var path: [OnboardingRoute] = [.welcome]

  // Email entered in the onboarding
  @Published var email: String = ""

  // nil = server provided no data, true = login, false = sign up
  @Published var existingUser: Bool? = nil

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
  func navigateAfterLogin() {
    if existingUser == false {
      // new user -> go to profile page
      navigate(to: .profile)
    } else {
      navigatingToMainView = true

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
