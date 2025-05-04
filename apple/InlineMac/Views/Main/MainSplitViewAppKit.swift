import AppKit
import Cocoa
import Combine
import SwiftUI

class MainSplitViewController: NSSplitViewController {
  private let dependencies: AppDependencies
  private var cancellables = Set<AnyCancellable>()

  private enum Metrics {
    static let sidebarWidthRange = 220.0 ... 400.0
    static let contentMinWidth: CGFloat = 300
  }

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    super.init(nibName: nil, bundle: nil)

    fetchData()
    setup()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    configureHierarchy()
  }

  func setup() {
    NotificationCenter.default
      .post(name: .requestNotificationPermission, object: nil)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}

// MARK: - Data Fetcher

extension MainSplitViewController {
  private func fetchData() {
    Task.detached {
      try await self.dependencies.realtime
        .invokeWithHandler(.getMe, input: .getMe(.init()))

      // wait for our own user to finish fetching
      // TODO: dedup from home sidebar
      Task.detached {
        try? await self.dependencies.data.getSpaces()
      }
      Task.detached {
        try? await self.dependencies.data.getPrivateChats()
      }
    }
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

class SidebarViewController: NSHostingController<AnyView> {
  private let dependencies: AppDependencies

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    super.init(rootView: SidebarContent().environment(dependencies: dependencies))
    sizingOptions = [
      //      .minSize,
    ]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
