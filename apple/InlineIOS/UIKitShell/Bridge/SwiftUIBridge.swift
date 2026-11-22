import Auth
import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import InlineUI
import RealtimeV2
import SwiftUI
import UIKit

/// Transitional bridge: on iOS 17+, screens that are not ported to UIKit yet keep their existing
/// SwiftUI implementation, hosted with the environment the SwiftUI shell used to provide. iOS 15–16
/// get the UIKit port when it exists, or `UnavailableFeatureViewController` until then.
///
/// Delete a screen's bridge entry once its UIKit port reaches parity.
@available(iOS 18.0, *)
@MainActor
enum SwiftUIBridge {
  static func controller<Content: View>(
    _ content: Content,
    shell: MainShellController,
    title: String? = nil
  ) -> UIViewController {
    let host = BridgedHostingController(rootView: AnyView(environment(content, shell: shell)))
    host.title = title
    host.navigationItem.largeTitleDisplayMode = .never
    host.hidesBottomBarWhenPushed = true
    return host
  }

  /// A sheet whose SwiftUI content brings its own NavigationStack.
  static func sheet<Content: View>(
    _ content: Content,
    shell: MainShellController,
    detents: [CompatSheetDetent] = [.large]
  ) -> UIViewController {
    let host = BridgedHostingController(rootView: AnyView(environment(content, shell: shell)))
    host.modalPresentationStyle = .pageSheet
    host.compatConfigureSheet(detents: detents, prefersGrabber: detents.count > 1)
    return host
  }

  private static func environment<Content: View>(_ content: Content, shell: MainShellController) -> some View {
    content
      .environment(\.auth, Auth.shared)
      .environment(\.transactions, Transactions.shared)
      .environment(\.realtimeV2, Api.realtime)
      .environment(shell.router)
      .appDatabase(AppDatabase.shared)
      .environmentObject(ThemeManager.shared)
      .environmentObject(shell.appDelegate.notificationHandler)
      .environmentObject(shell.appDelegate.nav)
      .environmentObject(INUserSettings.current.notification)
      .environmentObject(shell.mainViewRouter)
      .environmentObject(shell.mainViewRouter.onboardingNavigation)
      .environmentObject(Api.realtime.stateObject)
      .environmentObject(ApiClient.shared)
      .environmentObject(shell.data)
      .environmentObject(shell.spaces)
      .environmentObject(shell.homeList)
      .environmentObject(shell.bridgeSupport.userData)
      .environmentObject(shell.bridgeSupport.fileUpload)
      .environmentObject(shell.bridgeSupport.tabs)
  }
}

/// Objects the SwiftUI screens expect in their environment, owned by the shell.
@MainActor
final class BridgeSupport {
  let userData = UserData()
  let fileUpload = FileUploadViewModel()
  let tabs = TabsManager()
}

@available(iOS 18.0, *)
private final class BridgedHostingController: UIHostingController<AnyView> {
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
  }
}

/// iOS 15–16 stand-in for a screen whose UIKit port has not landed yet.
@MainActor
final class UnavailableFeatureViewController: UIViewController {
  private let featureTitle: String

  init(title: String) {
    featureTitle = title
    super.init(nibName: nil, bundle: nil)
    self.title = title
    hidesBottomBarWhenPushed = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground
    let empty = EmptyStateView(
      systemImage: "hammer",
      title: featureTitle,
      message: String(localized: "This screen isn't available on this version of iOS yet. It works on iOS 17 and later.")
    )
    empty.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(empty)
    empty.pinEdges(to: view)
  }
}
