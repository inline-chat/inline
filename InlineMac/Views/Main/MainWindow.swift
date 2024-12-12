import Combine
import InlineKit
import SwiftUI
import SwiftUIIntrospect

struct MainWindow: View {
  @EnvironmentObject var viewModel: MainWindowViewModel
  @EnvironmentObject var navigation: NavigationModel

  var body: some View {
    ZStack {
      // Background layer - no animation
      if viewModel.topLevelRoute == .onboarding {
        VisualEffectView(
          material: .sidebar,
          blendingMode: .behindWindow
        )
        .ignoresSafeArea(.all)
        .transaction { transaction in
          transaction.animation = nil
        }
      }

      // Content layer - with animation
      Group {
        switch viewModel.topLevelRoute {
        case .main:
          AuthenticatedWindowWrapper {
            MainView()
              .transition(
                .opacity
              )
          }

        case .onboarding:
          VisualEffectView(
            material: .sidebar,
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
    }
    .introspect(.window, on: .macOS(.v13, .v14, .v15)) {
      viewModel.windowInititized($0)
      navigation.windowManager = viewModel
    }
  }
}

enum TopLevelRoute {
  case onboarding
  case main
}

class MainWindowViewModel: ObservableObject {
  @Published var topLevelRoute: TopLevelRoute
  @Published var columnVisibility: NavigationSplitViewVisibility

  public var windowSize: PassthroughSubject<CGSize, Never> = .init()
  public var currentSize: CGSize = .zero

  private var cancellables = Set<AnyCancellable>()

  init() {
    if Auth.shared.isLoggedIn {
      topLevelRoute = .main
      columnVisibility = .all
    } else {
      topLevelRoute = .onboarding
      columnVisibility = .detailOnly
    }
  }

  private var window: NSWindow?

  // Used to trigger setup once
  private var windowInitilized = false

  func windowInititized(_ window: NSWindow) {
    let previousWindow = self.window
    self.window = window

    if previousWindow == window {
      return
    }
//    if windowInitilized {
//      return
//    }
//    windowInitilized = true
    Log.shared.debug("Window initialized")

    setUpWindowSizeMonitor()
    setupWindow(for: topLevelRoute)
  }

  func setUpWindowSizeMonitor() {
    // Cache the initial size
    currentSize = window?.frame.size ?? .zero

    // Observe via Combine
    NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)
      .compactMap { $0.object as? NSWindow }
      .sink { [weak self] window in
        if window == self?.window {
          self?.windowSize.send(window.frame.size)
          self?.currentSize = window.frame.size
        }
      }
      .store(in: &cancellables)
  }

  func navigate(_ route: TopLevelRoute) {
    //    columnVisibility = route == .main ? .automatic : .detailOnly
    topLevelRoute = route
    columnVisibility = route == .main ? .all : .detailOnly
    setupWindow(for: topLevelRoute)
  }

  private func setupWindow(for route: TopLevelRoute) {
    guard let window = window else { return }

    Log.shared.debug("Setting up window for route: \(route)")

    // configure titlebar based on we're in onboarding or main space view

    switch route {
    case .main:
      // Main style
      //      window.titlebarAppearsTransparent = false
      //      window.titleVisibility = .visible
      window.isMovableByWindowBackground = false
      window.isOpaque = true
      window.backgroundColor = NSColor.windowBackgroundColor
      setUpForInnerRoute(NavigationModel.shared.currentRoute)
    case .onboarding:
      // onboarding style
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
      window.isMovableByWindowBackground = true
      window.isOpaque = false
      window.backgroundColor = NSColor.clear
    }
  }

  public func setUpForInnerRoute(_ route: NavigationRoute) {
    Log.shared.debug("Setting up window for inner route: \(route)")
    switch route {
    case .spaceRoot:
      setToolbarVisibility(false)
    case .homeRoot:
      setToolbarVisibility(false)
    case .chat:
      setToolbarVisibility(true)
    case .chatInfo:
      setToolbarVisibility(false)
//    default:
//      setToolbarVisibility(true)
    }
  }

  public func setToolbarVisibility(_ isVisible: Bool) {
    guard let window = window else { return }

    // Keep the title bar (including traffic lights and sidebar toggle)
    //    window.titleVisibility = isVisible ? .visible : .hidden
    window.titlebarAppearsTransparent = !isVisible
    window.titlebarSeparatorStyle = isVisible ? .automatic : .none
//    window.toolbarStyle = .unified
  }

  public func resize(to newSize: CGSize) {
    guard let window = window else { return }

    let frame = window.frame
    let newFrame = NSRect(
      x: frame.origin.x,
      y: frame.origin.y + (frame.height - newSize.height), // Maintain top-left position
      width: newSize.width,
      height: newSize.height
    )

//    NSAnimationContext.runAnimationGroup { context in
//      context.duration = 0.2 // Animation duration
//      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
//      window.animator().setFrame(newFrame, display: true)
//    }
    ////

    window.setFrame(newFrame, display: true, animate: false)

    currentSize = newSize
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
