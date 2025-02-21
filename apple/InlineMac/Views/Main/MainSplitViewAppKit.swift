import AppKit
import Cocoa
import Combine
import SwiftUI

class MainSplitViewController: NSSplitViewController {
  private let dependencies: AppDependencies
  private var cancellables = Set<AnyCancellable>()

  private enum Metrics {
    static let sidebarWidthRange = 210.0 ... 400.0
    static let contentMinWidth: CGFloat = 300
  }

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    configureHierarchy()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}

// MARK: - Configuration

extension MainSplitViewController {
  private func configureHierarchy() {
    splitView.isVertical = true
    splitView.dividerStyle = .thin

    let sidebarItem = makeSidebarItem()
    let contentItem = makeContentItem()

    addSplitViewItem(sidebarItem)
    addSplitViewItem(contentItem)
  }

  private func makeSidebarItem() -> NSSplitViewItem {
    let controller = SidebarViewController(dependencies: dependencies)
    let item = NSSplitViewItem(sidebarWithViewController: controller)
    item.minimumThickness = Metrics.sidebarWidthRange.lowerBound
    item.maximumThickness = Metrics.sidebarWidthRange.upperBound
    item.canCollapse = true
    return item
  }

  private func makeContentItem() -> NSSplitViewItem {
    let controller = ContentViewController(dependencies: dependencies)

    let item = NSSplitViewItem(viewController: controller)
    item.minimumThickness = Metrics.contentMinWidth
    return item
  }
}

// MARK: - Toolbar Configuration

extension MainSplitViewController {}

// MARK: - Sidebar View Controller

class SidebarViewController: NSViewController {
  private let dependencies: AppDependencies

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
//    let effectView = NSVisualEffectView()
//    effectView.material = .sidebar
//    effectView.blendingMode = .behindWindow
//    effectView.state = .active
//    view = effectView

    view = makeSidebar()
  }

  private func makeSidebar() -> NSView {
    NSHostingView(rootView: SidebarContent().environment(dependencies: dependencies))
  }
}
