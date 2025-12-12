import AppKit
import InlineKit
import InlineUI
import SwiftUI

final class SpaceSettingsViewController: NSViewController {
  private let spaceId: Int64
  private let dependencies: AppDependencies

  init(spaceId: Int64, dependencies: AppDependencies) {
    self.spaceId = spaceId
    self.dependencies = dependencies
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    let view = SpaceSettingsView(spaceId: spaceId)
      .environment(dependencies: dependencies)

    let controller = NSHostingController(rootView: view)
    controller.sizingOptions = [.minSize]

    addChild(controller)
    self.view = controller.view
  }
}
