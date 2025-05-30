import AppKit
import Cocoa
import Combine
import Logger
import SwiftUI

class MainSplitViewController: NSSplitViewController {
  private let dependencies: AppDependencies
  private var cancellables = Set<AnyCancellable>()

  private enum Metrics {
    static let sidebarWidthRange = 240.0 ... 400.0
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

    // Add observer for app becoming active
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(refetchChats),
      name: NSApplication.didBecomeActiveNotification,
      object: nil
    )

    // Add observer for toggle sidebar
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(toggleCurrentSidebar),
      name: .toggleSidebar,
      object: nil
    )
  }

  @objc private func refetchChats() {
    Task.detached {
      do {
        try await self.dependencies.realtime
          .invokeWithHandler(.getChats, input: .getChats(.init()))
      } catch {
        Log.shared.error("Error refetching getChats", error: error)
      }
    }
  }

  @objc private func toggleCurrentSidebar() {
    guard let sidebarItem = splitViewItems.first else { return }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.3
      context.allowsImplicitAnimation = true
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      sidebarItem.animator().isCollapsed.toggle()
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}

// MARK: - Data Fetcher

extension MainSplitViewController {
  private func fetchData() {
    Task.detached {
      do {
        try await self.dependencies.realtime
          .invokeWithHandler(.getMe, input: .getMe(.init()))

        // wait for our own user to finish fetching
        // TODO: dedup from home sidebar
        Task.detached {
          try? await self.dependencies.data.getSpaces()
        }
      } catch {
        Log.shared.error("Error fetching getMe info", error: error)
      }

      Task.detached {
        do {
          try await self.dependencies.realtime
            .invokeWithHandler(.getChats, input: .getChats(.init()))
        } catch {
          Log.shared.error("Error fetching getChats", error: error)
        }
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
    item.preferredThicknessFraction = 0.35
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
