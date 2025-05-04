import AppKit
import SwiftUI

class NewChatViewController: NSViewController {
  var dependencies: AppDependencies

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private lazy var swiftUIView: some View =
    NewChatSwiftUI(spaceId: self.dependencies.nav.currentSpaceId ?? 0)
      .environment(dependencies: dependencies)

  override func loadView() {
    let controller = NSHostingController(
      rootView: swiftUIView
    )

    // Set the sizing options so the SwiftUI view doesn't mess up the window
    controller.sizingOptions = [
      .minSize,
    ]

    addChild(controller)
    view = controller.view
  }
}
