import AppKit
import InlineKit
import SwiftUI

final class PlaceholderContentViewController: NSViewController {
  private let message: String?
  private let imageView = NSImageView()

  init(message: String?) {
    self.message = message
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    imageView.image = NSImage(named: "inline-logo-bg")
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.translatesAutoresizingMaskIntoConstraints = false

    let container = AppearanceAwareView { [weak self] in
      self?.updateForAppearance()
    }

    container.addSubview(imageView)

    NSLayoutConstraint.activate([
      imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      imageView.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
      imageView.heightAnchor.constraint(lessThanOrEqualToConstant: 320),
    ])

    if let message, !message.isEmpty {
      let label = NSTextField(labelWithString: message)
      label.alignment = .center
      label.textColor = .secondaryLabelColor
      label.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(label)
      NSLayoutConstraint.activate([
        label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 12),
      ])
    }

    view = container
    updateForAppearance()
  }

  private func updateForAppearance() {
    let bestMatch = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
    let isDarkMode = bestMatch == .darkAqua
    imageView.alphaValue = isDarkMode ? 0.2 : 1.0
  }
}

private final class AppearanceAwareView: NSView {
  private let onChange: () -> Void

  init(onChange: @escaping () -> Void) {
    self.onChange = onChange
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    onChange()
  }
}
