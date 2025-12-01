import AppKit
import Combine
import InlineKit
import InlineMacUI
import InlineUI
import Observation
import SwiftUI

class MainSidebarHeaderView: NSView {
  private static let titleHeight: CGFloat = MainSidebar.itemHeight
  private static let height: CGFloat = MainSidebarHeaderView.titleHeight
  private static let iconSize: CGFloat = Theme.sidebarTitleIconSize

  private let dependencies: AppDependencies
  private var nav2: Nav2? { dependencies.nav2 }

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    setupViews()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private lazy var textView: NSTextField = {
    let view = NSTextField(labelWithString: "")
    view.font = MainSidebar.font
    view.textColor = .secondaryLabelColor
    view.lineBreakMode = .byTruncatingTail
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var iconHost: NSHostingView<AnyView> = {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    host.translatesAutoresizingMaskIntoConstraints = false
    host.setContentHuggingPriority(.required, for: .horizontal)
    host.setContentCompressionResistancePriority(.required, for: .horizontal)
    return host
  }()

  private func setupViews() {
    addSubview(iconHost)
    addSubview(textView)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: MainSidebarHeaderView.height),

      iconHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
      iconHost.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconHost.widthAnchor.constraint(equalToConstant: Self.iconSize),
      iconHost.heightAnchor.constraint(equalToConstant: Self.iconSize),

      textView.leadingAnchor.constraint(equalTo: iconHost.trailingAnchor, constant: MainSidebar.iconTrailingPadding),
      textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      textView.centerYAnchor.constraint(equalTo: centerYAnchor),
      textView.heightAnchor.constraint(lessThanOrEqualToConstant: MainSidebarHeaderView.height - 16),
    ])
  }

  override func layout() {
    super.layout()

    textView.stringValue = nav2?.activeTab.tabTitle ?? "Home"

    // TODO: Don't create a new view every time here, it can be called too much
    iconHost.rootView = AnyView(iconView(for: nav2?.activeTab))
  }

  @ViewBuilder
  private func iconView(for tab: TabId?) -> some View {
    switch tab {
      case let .space(id, name):
        let space = Space(id: id, name: name, date: Date())
        SpaceAvatar(space: space, size: Self.iconSize)
      default:
        Image(systemName: "house.fill")
          .resizable()
          .scaledToFit()
          .frame(width: Self.iconSize, height: Self.iconSize)
          .foregroundStyle(Color.secondary)
    }
  }
}
