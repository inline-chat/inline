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
        if self.viewModel.goingBack {
            return self.routeTransition2
        } else {
            return self.routeTransition1
        }
    }

    var body: some View {
        ZStack {
            switch self.viewModel.path.last {
            case .welcome:
                OnboardingWelcome().transition(self.routeTransition)
            case .enterEmail:
                OnboardingEnterEmail().transition(self.routeTransition)
            case .enterCode:
                OnboardingEnterCode().transition(self.routeTransition)
            case .profile:
                OnboardingProfile().transition(self.routeTransition)
            case .none:
                OnboardingWelcome().transition(self.routeTransition)
            }
        }
        .animation(.snappy, value: self.viewModel.path)

        .toolbar(content: {
            if self.viewModel.canGoBack {
                ToolbarItem(placement: .navigation) {
                    Button {
                        self.viewModel.goBack()
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
        .environmentObject(self.viewModel)
        .task {
            self.viewModel.setMainWindowViewModel(self.windowViewModel)
        }
    }
}

enum OnboardingRoute {
    case welcome
    case enterEmail
    case enterCode
    case profile
}

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
        self.path.count > 1
    }

    func navigate(to route: OnboardingRoute) {
        DispatchQueue.main.async {
            self.path.append(route)
        }
    }

    // Special navigate that decides next step after user is verified and logged in
    // i.e. we have token and current user id, should we open profile or main view?
    func navigateAfterLogin() {
        if self.existingUser == false {
            // new user -> go to profile page
            self.navigate(to: .profile)
        } else {
            self.navigatingToMainView = true

            self.mainWindowViewModel?.navigate(.main)
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
        self.mainWindowViewModel = mvm
    }
}

#Preview {
    Onboarding()
        .environmentObject(MainWindowViewModel())
        .environmentObject(OnboardingViewModel())
        .frame(width: 900, height: 600)
}
