import UIKit
import ChatListCore

@MainActor
final class PhoneDecorations {
  private var views: [String: UILabel] = [:]

  func frame(for id: String) -> CGRect? { views[id]?.frame }

  func present(in root: UIView, placements: [ChatListDecorationPlacement]) {
    let visible = Set(placements.map(\.id))
    for id in Array(views.keys) where !visible.contains(id) {
      views[id]?.removeFromSuperview()
      views.removeValue(forKey: id)
    }
    for placement in placements {
      let view = views[placement.id] ?? makeView(for: placement.id, in: root)
      view.frame = placement.frame
      view.alpha = placement.opacity
    }
  }

  private func makeView(for id: String, in root: UIView) -> UILabel {
    let view = UILabel()
    view.text = id.hasPrefix("badge-") ? "GROUP" : "👤"
    view.textAlignment = .center
    view.textColor = .white
    view.font = .systemFont(ofSize: id.hasPrefix("badge-") ? 10 : 16, weight: .semibold)
    view.backgroundColor = (id.hasPrefix("badge-") ? UIColor.systemTeal : UIColor.systemIndigo)
      .withAlphaComponent(0.84)
    view.layer.cornerRadius = id.hasPrefix("badge-") ? 8 : 14
    view.clipsToBounds = true
    root.addSubview(view)
    views[id] = view
    return view
  }
}
