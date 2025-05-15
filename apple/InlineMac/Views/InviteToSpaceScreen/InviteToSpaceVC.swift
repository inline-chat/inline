import AppKit
import InlineKit
import InlineUI
import SwiftUI

class InviteToSpaceViewController: NSViewController {
  var spaceId: Int64
  var dependencies: AppDependencies

  init(spaceId: Int64, dependencies: AppDependencies) {
    self.spaceId = spaceId
    self.dependencies = dependencies
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private lazy var swiftUIView: some View =
    InviteToSpaceView(spaceId: self.spaceId)
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
