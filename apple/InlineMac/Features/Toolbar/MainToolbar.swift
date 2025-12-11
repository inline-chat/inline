import AppKit
import Combine
import InlineKit
import InlineUI
import SwiftUI
import Translation

enum MainToolbarItemIdentifier: Hashable, Sendable {
  case navigationBack
  case navigationForward
  case title
  case spacer
  case translationIcon(peer: Peer)
  case participants(peer: Peer)
  case chatTitle(peer: Peer)
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
    MainToolbarItems(items: [.navigationBack, .navigationForward, .title])
  }
}

final class ToolbarState: ObservableObject {
  @Published var currentItems: [MainToolbarItemIdentifier]

  init() {
    currentItems = [.navigationBack, .navigationForward]
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
    }
  }

  // MARK: - State

  var state = ToolbarState()

  // MARK: - Setup

  private func setupView() {
    wantsLayer = true
    layer?.backgroundColor = Theme.windowContentBackgroundColor.cgColor

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
    layer?.backgroundColor = transparent ? .clear : Theme.windowContentBackgroundColor.cgColor
    super.updateLayer()
  }
}

// Swift UI representation of the toolbar
struct ToolbarSwiftUIView: View {
  @ObservedObject var state: ToolbarState
  var dependencies: AppDependencies

  var body: some View {
    HStack(spacing: 12) {
      ForEach(Array(state.currentItems.enumerated()), id: \.offset) { _, item in
        switch item {
          case .navigationBack:
            Button {
              dependencies.nav2?.goBack()
            } label: {
              Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .controlSize(.large)
            .disabled(!(dependencies.nav2?.canGoBack ?? false))

          case .navigationForward:
            Button {
              dependencies.nav2?.goForward()
            } label: {
              Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .controlSize(.large)
            .disabled(!(dependencies.nav2?.canGoForward ?? false))

          case let .translationIcon(peer):
            TranslationButton(peer: peer)
              .buttonStyle(.plain)
              .controlSize(.large)
              .frame(height: Theme.toolbarHeight - 8)
              .id(peer.id)

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
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 24)
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
