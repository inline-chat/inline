import AppKit
import ChatListCore

@MainActor
final class MacDecorations {
  private var views: [String: NSTextField] = [:]

  func frame(for id: String) -> CGRect? { views[id]?.frame }

  func present(in root: NSView, placements: [ChatListDecorationPlacement]) {
    let visible = Set(placements.map(\.id))
    for id in Array(views.keys) where !visible.contains(id) {
      views[id]?.removeFromSuperview()
      views.removeValue(forKey: id)
    }
    for placement in placements {
      let view = views[placement.id] ?? makeView(for: placement.id, in: root)
      view.frame = placement.frame
      view.alphaValue = placement.opacity
    }
  }

  private func makeView(for id: String, in root: NSView) -> NSTextField {
    let view = NSTextField(labelWithString: id.hasPrefix("badge-") ? "GROUP" : "👤")
    view.alignment = .center
    view.font = .systemFont(ofSize: id.hasPrefix("badge-") ? 10 : 16, weight: .semibold)
    view.wantsLayer = true
    view.layer?.backgroundColor = (id.hasPrefix("badge-") ? NSColor.systemTeal : NSColor.systemIndigo)
      .withAlphaComponent(0.84).cgColor
    view.layer?.cornerRadius = id.hasPrefix("badge-") ? 8 : 14
    view.textColor = .white
    root.addSubview(view)
    views[id] = view
    return view
  }
}
