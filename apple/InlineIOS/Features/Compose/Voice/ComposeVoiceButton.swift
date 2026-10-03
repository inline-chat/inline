import UIKit

final class ComposeVoiceButton: UIButton {
  static let size: CGFloat = 28

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    let hitBounds = bounds.insetBy(dx: -8, dy: -8)
    return hitBounds.contains(point)
  }

  private func setup() {
    translatesAutoresizingMaskIntoConstraints = false
    frame = CGRect(origin: .zero, size: CGSize(width: Self.size, height: Self.size))

    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: "mic.fill")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
    )
    config.baseForegroundColor = .tertiaryLabel
    config.cornerStyle = .capsule
    config.contentInsets = .zero
    configuration = config

    accessibilityLabel = "Record voice message"
    isHidden = true
  }
}
