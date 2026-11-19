import InlineKit
import InlineMessageLayout
import UIKit

/// Time and delivery status. Both pieces sit at frames derived from the planned time frame.
final class MessageTimeView: UIView {
  private let pillView = UIView()
  private let textView = MessageTextView()
  private let statusView = UIImageView()
  private var status: MessageSendingStatus?
  private var statusSize: CGSize = .zero
  private var pillPadding: CGSize = .zero

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    statusView.contentMode = .scaleAspectFit
    pillView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
    pillView.isHidden = true
    addSubview(pillView)
    addSubview(textView)
    addSubview(statusView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    time: TextLayout,
    status: MessageSendingStatus?,
    statusSize: CGSize,
    statusColor: UIColor,
    pillPadding: CGSize?,
    animated: Bool
  ) {
    self.pillPadding = pillPadding ?? .zero
    pillView.isHidden = pillPadding == nil
    textView.setLayout(time)
    self.statusSize = statusSize
    statusView.tintColor = statusColor
    statusView.isHidden = status == nil
    if self.status != status {
      let previous = statusView.image
      self.status = status
      statusView.preferredSymbolConfiguration = Self.symbolConfiguration(for: status, traits: traitCollection)
      let image = Self.symbolName(for: status).flatMap { UIImage(systemName: $0) }
      statusView.image = image
      // Like Telegram, the glyph swaps at once and the check pops in from 130% over 0.1 s.
      heldPop = false
      if animated, previous != nil, status == .sent, !UIAccessibility.isReduceMotionEnabled {
        if holdsStatusPop { heldPop = true } else { popStatus() }
      }
    }
    layoutPieces()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layoutPieces()
  }

  /// Set while the message's bubble is out of sight (flying in from the composer): a check that
  /// arrives meanwhile pops when it is shown again.
  var holdsStatusPop = false {
    didSet {
      guard !holdsStatusPop, heldPop else { return }
      heldPop = false
      popStatus()
    }
  }

  private var heldPop = false

  /// Forgets a held pop, for a view about to show another message.
  func dropHeldStatusPop() {
    heldPop = false
  }

  private func popStatus() {
    let pop = CABasicAnimation(keyPath: "transform.scale")
    pop.fromValue = 1.3
    pop.toValue = 1
    pop.duration = 0.1
    pop.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    statusView.layer.add(pop, forKey: "statusPop")
  }

  private func layoutPieces() {
    pillView.frame = bounds
    pillView.layer.cornerRadius = bounds.height / 2
    let time = textView.layout.size
    textView.textFrame = CGRect(
      x: pillPadding.width,
      y: (bounds.height - time.height) / 2,
      width: time.width,
      height: time.height
    )
    statusView.frame = CGRect(
      x: bounds.width - pillPadding.width - statusSize.width,
      y: (bounds.height - statusSize.height) / 2,
      width: statusSize.width,
      height: statusSize.height
    )
  }

  static func symbolSize(traits: UITraitCollection) -> CGSize {
    let side = ChatTypography.font(11, style: .caption2, compatibleWith: traits).pointSize
    return CGSize(width: side, height: side)
  }

  private static func symbolName(for status: MessageSendingStatus?) -> String? {
    switch status {
    case .sent: "checkmark"
    case .sending: "clock"
    case .failed: "exclamationmark"
    case .none: nil
    }
  }

  private static func symbolConfiguration(
    for status: MessageSendingStatus?,
    traits: UITraitCollection
  ) -> UIImage.SymbolConfiguration {
    UIImage.SymbolConfiguration(font: ChatTypography.font(
      status == .sending ? 10 : 11,
      weight: .medium,
      style: .caption2,
      compatibleWith: traits
    ))
  }
}
