import AppKit
import Combine
import InlineKit
import InlineUI
import SwiftUI
import Translation

enum MainToolbarItemIdentifier: Hashable, Sendable {
  case navigationButtons
  case title
  case spacer
  case translationIcon(peer: Peer)
  case participants(peer: Peer)
  case chatTitle(peer: Peer)
  case nudge(peer: Peer)
}

struct MainToolbarItems {
  var items: [MainToolbarItemIdentifier]
  var transparent: Bool {
    items.count == 0
  }
}

extension MainToolbarItems {
  static var empty: MainToolbarItems {
    MainToolbarItems(items: [])
  }

  static func defaultItems() -> MainToolbarItems {
    MainToolbarItems(items: [.navigationButtons, .title])
  }
}

final class ToolbarState: ObservableObject {
  @Published var currentItems: [MainToolbarItemIdentifier]

  init() {
    currentItems = [.navigationButtons]
  }

  func update(with items: [MainToolbarItemIdentifier]) {
    currentItems = items
  }
}

class MainToolbarView: NSView {
  private var dependencies: AppDependencies
  private var hostingView: NSHostingView<ToolbarSwiftUIView>?

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(with toolbar: MainToolbarItems) {
    state.update(with: toolbar.items)
    transparent = toolbar.transparent

    // Force SwiftUI to refresh in case Observation misses changes from AppKit
    // hostingView?.rootView = ToolbarSwiftUIView(
    //   state: state,
    //   dependencies: dependencies
    // )
  }

  // MARK: - UI

  var transparent: Bool = false {
    didSet {
      updateLayer()
      hostingView?.isHidden = transparent
    }
  }

  // MARK: - State

  var state = ToolbarState()

  // MARK: - Setup

  private func setupView() {
    wantsLayer = true
    layer?.backgroundColor = .clear

    // Add SwiftUI view to the toolbar
    let hostingView = NSHostingView(
      rootView: ToolbarSwiftUIView(
        state: state,
        dependencies: dependencies
      )
    )
    self.hostingView = hostingView
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    hostingView.setContentHuggingPriority(
      .defaultLow,
      for: .horizontal
    )
    addSubview(hostingView)
    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
      hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
      hostingView.topAnchor.constraint(equalTo: topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  // MARK: - Lifecycle

  override func updateLayer() {
    layer?.backgroundColor = .clear
    super.updateLayer()
  }
}

// Swift UI representation of the toolbar
struct ToolbarSwiftUIView: View {
  @ObservedObject var state: ToolbarState
  var dependencies: AppDependencies

  private let navButtonSymbolSize: CGFloat = 18
  private let navButtonSymbolFrame: CGFloat = 24
  private let navButtonHitFrame: CGFloat = 32

  var body: some View {
    ZStack(alignment: .leading) {
      toolbarBackground
      toolbarContent
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }
    .frame(height: Theme.toolbarHeight)
    .ignoresSafeArea()
  }

  private var toolbarBackground: some View {
    let baseColor = Color(nsColor: Theme.windowContentBackgroundColor)
    return LinearGradient(
      gradient: Gradient(stops: [
        .init(color: baseColor.opacity(1), location: 0),
        .init(color: baseColor.opacity(0.9), location: 0.2),
        .init(color: baseColor.opacity(0.8), location: 0.5),
        .init(color: baseColor.opacity(0.2), location: 0.9),
        .init(color: baseColor.opacity(0), location: 1),
      ]),
      startPoint: .top,
      endPoint: .bottom
    )
  }

  @ViewBuilder
  private var toolbarContent: some View {
    HStack(spacing: 12) {
      ForEach(Array(state.currentItems.enumerated()), id: \.offset) { _, item in
        switch item {
          case .navigationButtons:
            navigationButtons

          case let .translationIcon(peer):
            if #available(macOS 26.0, *) {
              TranslationButton(peer: peer)
                .buttonStyle(.glass)
                .controlSize(.large)
                // .padding(.horizontal, 0)
                // .frame(height: Theme.toolbarHeight)
                .id(peer.id)
            } else {
              TranslationButton(peer: peer)
                .buttonStyle(.plain)
                .controlSize(.extraLarge)
                // .frame(height: Theme.toolbarHeight - 8)
                .id(peer.id)
            }

          case let .nudge(peer):
            if #available(macOS 26.0, *) {
              NudgeButton(peer: peer)
                .buttonStyle(.glass)
                .controlSize(.large)
                .id(peer.id)
            } else {
              NudgeButton(peer: peer)
                .buttonStyle(.plain)
                .controlSize(.extraLarge)
                .id(peer.id)
            }

          case let .participants(peer):
            ParticipantsToolbarButton(peer: peer, dependencies: dependencies)
              .id(peer.id)

          case let .chatTitle(peer):
            ChatTitleToolbarRepresentable(peer: peer, dependencies: dependencies)
              .id(peer.id)

          case .spacer:
            Spacer()

          case .title:
            EmptyView()
        }
      }
    }
  }

  private var navigationBackButton: some View {
    navigationButton(
      systemName: "chevron.left",
      isEnabled: dependencies.nav2?.canGoBack ?? false
    ) {
      dependencies.nav2?.goBack()
    }
  }

  private var navigationButtons: some View {
    HStack(spacing: 0) {
      navigationBackButton
      navigationForwardButton
    }
  }

  private var navigationForwardButton: some View {
    navigationButton(
      systemName: "chevron.right",
      isEnabled: dependencies.nav2?.canGoForward ?? false
    ) {
      dependencies.nav2?.goForward()
    }
  }

  private func navigationButton(
    systemName: String,
    isEnabled: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: navButtonSymbolSize, weight: .regular))
        .frame(width: navButtonSymbolFrame, height: navButtonSymbolFrame)
        .frame(width: navButtonHitFrame, height: navButtonHitFrame)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
  }
}

// Bridge the existing AppKit chat title toolbar into SwiftUI
private struct ChatTitleToolbarRepresentable: NSViewRepresentable {
  let peer: Peer
  let dependencies: AppDependencies

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    let toolbarItem = ChatTitleToolbar(peer: peer, dependencies: dependencies)
    context.coordinator.toolbarItem = toolbarItem
    return toolbarItem.view ?? NSView()
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.toolbarItem?.configure()
  }

  class Coordinator {
    var toolbarItem: ChatTitleToolbar?
  }
}
