import InlineKit
import UIKit

/// Sits in the composer's place in a chat with a bot the viewer can't message:
/// says whose bot it is, and offers to message the owner. Same pill as the
/// composer so the chat's bottom edge doesn't change shape.
final class BotNoAccessBarView: UIView {
  private let pill: UIVisualEffectView
  private let iconView = UIImageView()
  private let label = UILabel()
  private let actionButton = UIButton(type: .system)
  private var ownerUserID: Int64?
  private var onMessageOwner: ((Int64) -> Void)?

  override init(frame: CGRect) {
    if #available(iOS 26.0, *) {
      pill = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    } else {
      pill = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    }
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false

    pill.translatesAutoresizingMaskIntoConstraints = false
    pill.layer.cornerRadius = ComposeView.minHeight / 2
    pill.layer.cornerCurve = .continuous
    pill.clipsToBounds = true
    addSubview(pill)

    iconView.image = UIImage(systemName: "lock.fill")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    )
    iconView.tintColor = .secondaryLabel
    iconView.setContentHuggingPriority(.required, for: .horizontal)
    iconView.isAccessibilityElement = false

    label.font = .preferredFont(forTextStyle: .subheadline)
    label.adjustsFontForContentSizeCategory = true
    label.textColor = .secondaryLabel
    label.numberOfLines = 2
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    var configuration = UIButton.Configuration.plain()
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
    configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
      var attributes = attributes
      attributes.font = UIFontMetrics(forTextStyle: .subheadline)
        .scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
      return attributes
    }
    actionButton.configuration = configuration
    actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    actionButton.setContentHuggingPriority(.required, for: .horizontal)
    actionButton.addTarget(self, action: #selector(messageOwner), for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [iconView, label, actionButton])
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 8
    stack.setCustomSpacing(10, after: label)
    stack.translatesAutoresizingMaskIntoConstraints = false
    pill.contentView.addSubview(stack)

    NSLayoutConstraint.activate([
      pill.leadingAnchor.constraint(equalTo: leadingAnchor),
      pill.trailingAnchor.constraint(equalTo: trailingAnchor),
      pill.topAnchor.constraint(equalTo: topAnchor),
      pill.bottomAnchor.constraint(equalTo: bottomAnchor),
      heightAnchor.constraint(greaterThanOrEqualToConstant: ComposeView.minHeight),
      stack.leadingAnchor.constraint(equalTo: pill.contentView.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: pill.contentView.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: pill.contentView.topAnchor, constant: 6),
      stack.bottomAnchor.constraint(equalTo: pill.contentView.bottomAnchor, constant: -6),
    ])
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(_ notice: BotNoAccessNotice, onMessageOwner: @escaping (Int64) -> Void) {
    self.onMessageOwner = onMessageOwner
    ownerUserID = notice.ownerUserID
    label.text = notice.text
    let showsAction = notice.actionTitle != nil && notice.ownerUserID != nil
    actionButton.isHidden = !showsAction
    actionButton.configuration?.title = notice.actionTitle
  }

  @objc private func messageOwner() {
    guard let ownerUserID else { return }
    onMessageOwner?(ownerUserID)
  }
}
