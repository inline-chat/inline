import UIKit

final class ComposeVoiceButton: UIButton {
  static let size: CGFloat = 26

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    let hitBounds = bounds.insetBy(dx: -9, dy: -9)
    return hitBounds.contains(point)
  }

  private func setup() {
    translatesAutoresizingMaskIntoConstraints = false
    frame = CGRect(origin: .zero, size: CGSize(width: Self.size, height: Self.size))

    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: "mic.fill")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
    )
    config.baseForegroundColor = .secondaryLabel
    config.cornerStyle = .capsule
    config.contentInsets = .zero
    configuration = config

    accessibilityLabel = "Record voice message"
    isHidden = true

    configurationUpdateHandler = { [weak self] button in
      guard let self else { return }
      let scale: CGFloat = button.isHighlighted ? 0.86 : 1
      UIView.animate(
        withDuration: 0.16,
        delay: 0,
        options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut]
      ) {
        self.transform = CGAffineTransform(scaleX: scale, y: scale)
      }
    }
  }
}
