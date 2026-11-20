import AppKit
import SwiftUI

struct AppKitRouteViewController<Controller: NSViewController>: NSViewControllerRepresentable {
  let make: () -> Controller
  var update: (Controller) -> Void = { _ in }
  var dismantle: (Controller) -> Void = { _ in }

  func makeCoordinator() -> Coordinator {
    Coordinator(dismantle: dismantle)
  }

  func makeNSViewController(context: Context) -> Controller {
    make()
  }

  func updateNSViewController(_ nsViewController: Controller, context: Context) {
    update(nsViewController)
  }

  /// Takes the size SwiftUI proposes. Without this SwiftUI sizes the route from the AppKit view's
  /// layout traits, an Auto Layout fitting pass over the whole chat on every graph update, and the
  /// graph updates on every frame of a message list scroll. The frames around the route set its
  /// limits; ideal-size queries (an unspecified dimension) keep the default path.
  func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: Controller, context: Context) -> CGSize? {
    guard let width = proposal.width, let height = proposal.height else { return nil }
    return CGSize(width: width, height: height)
  }

  static func dismantleNSViewController(_ nsViewController: Controller, coordinator: Coordinator) {
    coordinator.dismantle(nsViewController)
  }

  final class Coordinator {
    let dismantle: (Controller) -> Void

    init(dismantle: @escaping (Controller) -> Void) {
      self.dismantle = dismantle
    }
  }
}
