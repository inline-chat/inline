import SwiftUI
import UIKit

struct ContextMenuItem {
  let title: String
  let icon: UIImage?
  let action: () -> Void
  let isDestructive: Bool

  init(title: String, icon: UIImage? = nil, isDestructive: Bool = false, action: @escaping () -> Void) {
    self.title = title
    self.icon = icon
    self.isDestructive = isDestructive
    self.action = action
  }
}

enum ContextMenuElement {
  case item(ContextMenuItem)
  case separator
}

final class ContextMenuView: UIView {
  private let elements: [ContextMenuElement]
  private var hostingController: UIHostingController<ContextMenuContentView>?

  init(elements: [ContextMenuElement]) {
    self.elements = elements
    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    backgroundColor = .clear
    layer.cornerRadius = 13
    layer.masksToBounds = true
    layer.cornerCurve = .continuous

    let rootView = ContextMenuContentView(elements: elements)
    let hosting = UIHostingController(rootView: rootView)
    hosting.view.translatesAutoresizingMaskIntoConstraints = false
    hosting.view.backgroundColor = UIColor.clear
    addSubview(hosting.view)
    NSLayoutConstraint.activate([
      hosting.view.topAnchor.constraint(equalTo: topAnchor),
      hosting.view.leadingAnchor.constraint(equalTo: leadingAnchor),
      hosting.view.trailingAnchor.constraint(equalTo: trailingAnchor),
      hosting.view.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    hostingController = hosting
  }

  // MARK: - Presentation Animations

  /// Preparation – no animation by default.
  func prepareForPresentation() {
    alpha = 1
    transform = .identity
  }

  func animateIn(after delay: TimeInterval = 0) {
    // No entrance animation – instant appearance.
  }

  func animateOut(completion: (() -> Void)? = nil) {
    // Immediate dismissal.
    completion?()
  }
}
