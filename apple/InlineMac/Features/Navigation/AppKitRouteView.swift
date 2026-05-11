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
