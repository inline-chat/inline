import AppKit
import InlineKit
import InlineUI
import SwiftUI
import Invite

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
    InviteView(
      destination: .space(id: self.spaceId),
      onManageMembers: { [dependencies] destinationSpaceID in
        if let nav2 = dependencies.nav2 {
          nav2.navigate(to: .members(spaceId: destinationSpaceID))
        } else if let nav3 = dependencies.nav3 {
          nav3.open(.members(spaceId: destinationSpaceID))
        } else {
          dependencies.nav.open(.members(spaceId: destinationSpaceID))
        }
      },
      onOpenChat: { [dependencies] peer in
        dependencies.openChatRoute(peer: peer)
      }
    )
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
