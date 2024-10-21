import InlineKit
import SwiftUI
import SwiftUIIntrospect

struct MainWindow: View {
    @EnvironmentObject var viewModel: MainWindowViewModel
    
    var body: some View {
        ZStack {
            switch viewModel.topLevelRoute {
            case .main:
                MainView()
                    .transition(
                        .opacity
                    )
                
            case .onboarding:
                VisualEffectView(
                    material: .popover,
                    blendingMode: .behindWindow
                )
                .ignoresSafeArea(.all)
                
                Onboarding()
                    .transition(
                        .opacity
                    )
            }
        }
        .animation(.snappy, value: viewModel.topLevelRoute)
        .introspect(.window, on: .macOS(.v13, .v14, .v15)) {
            viewModel.windowInititized($0)
        }
    }
}

enum TopLevelRoute {
    case onboarding
    case main
}

class MainWindowViewModel: ObservableObject {
    @Published var topLevelRoute: TopLevelRoute
    
    init() {
        if Auth.shared.isLoggedIn {
            topLevelRoute = .main
        } else {
            topLevelRoute = .onboarding
        }
    }
     
    private var window: NSWindow?
    
    func windowInititized(_ window: NSWindow) {
        self.window = window
        setupWindow(for: topLevelRoute)
    }
    
    func navigate(_ route: TopLevelRoute) {
        topLevelRoute = route
        setupWindow(for: topLevelRoute)
    }
    
    private func setupWindow(for route: TopLevelRoute) {
        guard let window = window else { return }
        
        // configure titlebar based on we're in onboarding or main space view
        
        switch route {
        case .main:
            // Main style
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = false
            window.isOpaque = true
            window.backgroundColor = NSColor.windowBackgroundColor
        case .onboarding:
            // onboarding style
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = NSColor.clear
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    typealias NSViewType = NSVisualEffectView
    
    var material: NSVisualEffectView.Material = .fullScreenUI
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active

        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
