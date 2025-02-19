import AppKit
import SwiftUI

struct VisualEffectView: NSViewRepresentable {
  typealias NSViewType = NSVisualEffectView

  var material: NSVisualEffectView.Material = .fullScreenUI
  var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = blendingMode
    view.state = .followsWindowActiveState
    // view.state = .active

    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
