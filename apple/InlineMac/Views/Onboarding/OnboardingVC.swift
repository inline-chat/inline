import AppKit
import SwiftUI

class OnboardingViewController: NSViewController {
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
    Onboarding()
      .environment(dependencies: dependencies)

  override func loadView() {
    let controller = NSHostingController(
      rootView: swiftUIView
    )

    controller.sizingOptions = [
      .minSize,
    ]

    if #available(macOS 14.0, *) {
      // controller.sceneBridgingOptions = []
    }

    addChild(controller)
    view = controller.view
  }
}
