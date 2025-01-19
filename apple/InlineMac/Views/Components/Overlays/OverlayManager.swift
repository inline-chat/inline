import SwiftUI

class OverlayManager: ObservableObject {
  func showError(title: String? = nil, message: String, error: Error? = nil) {
    // TODO: Show error to user via a toast or something
    let alert = NSAlert()
    alert.messageText = title ?? "Something went wrong"
    alert.messageText = message
    alert.informativeText = error?.localizedDescription ?? ""
    alert.alertStyle = .critical
    alert.addButton(withTitle: "OK")

    alert.runModal() // shows alert modally
  }
}
