import AppKit
import Auth
import SwiftUI

final class LoadingViewController: NSViewController {
  override func loadView() {
    let controller = NSHostingController(rootView: LoadingView())
    controller.sizingOptions = [
      .minSize,
    ]
    addChild(controller)
    view = controller.view
  }
}

private struct LoadingView: View {
  @ObservedObject private var auth = Auth.shared

  private var label: String {
    switch auth.status {
    case .locked:
      "Unlocking..."
    case .hydrating:
      "Loading..."
    case .authenticated, .unauthenticated, .reauthRequired:
      "Loading..."
    }
  }

  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text(label)
        .font(.headline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.clear)
  }
}

