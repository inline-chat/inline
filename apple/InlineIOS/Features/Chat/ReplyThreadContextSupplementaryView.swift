import UIKit

final class ReplyThreadContextSupplementaryView: UICollectionReusableView {
  static let reuseIdentifier = "ReplyThreadContextSupplementaryView"
  static let elementKind = "ReplyThreadContextSupplementaryViewKind"
  static let estimatedHeight: CGFloat = 160

  private let contentContainer: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.transform = CGAffineTransform(scaleX: 1, y: -1)
    return view
  }()

  private let separatorBlurView: UIVisualEffectView = {
    let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private let separatorLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 12, weight: .medium)
    label.textColor = .label
    label.textAlignment = .center
    label.text = "Replies"
    return label
  }()

  private var anchorView: ReplyThreadAnchorHeaderView?
  private var currentChatId: Int64?
  private var currentSpaceId: Int64?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    currentChatId = nil
    currentSpaceId = nil
    anchorView?.removeFromSuperview()
    anchorView = nil
  }

  private func setupView() {
    backgroundColor = .clear

    addSubview(contentContainer)
    contentContainer.addSubview(separatorBlurView)
    separatorBlurView.contentView.addSubview(separatorLabel)

    NSLayoutConstraint.activate([
      contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
      contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
      contentContainer.topAnchor.constraint(equalTo: topAnchor),
      contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

      separatorBlurView.centerXAnchor.constraint(equalTo: contentContainer.centerXAnchor),
      separatorBlurView.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 6),
      separatorBlurView.heightAnchor.constraint(equalToConstant: 20),
      separatorBlurView.leadingAnchor.constraint(greaterThanOrEqualTo: contentContainer.leadingAnchor, constant: 16),
      separatorBlurView.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor, constant: -16),

      separatorLabel.leadingAnchor.constraint(equalTo: separatorBlurView.contentView.leadingAnchor, constant: 8),
      separatorLabel.trailingAnchor.constraint(equalTo: separatorBlurView.contentView.trailingAnchor, constant: -8),
      separatorLabel.centerYAnchor.constraint(equalTo: separatorBlurView.contentView.centerYAnchor),
    ])
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    separatorBlurView.layer.cornerRadius = separatorBlurView.bounds.height / 2
    separatorBlurView.layer.cornerCurve = .continuous
    separatorBlurView.clipsToBounds = true
  }

  func configure(chatId: Int64, spaceId: Int64) {
    guard currentChatId != chatId || currentSpaceId != spaceId else { return }

    currentChatId = chatId
    currentSpaceId = spaceId
    anchorView?.removeFromSuperview()

    let anchorView = ReplyThreadAnchorHeaderView(chatId: chatId, spaceId: spaceId)
    anchorView.translatesAutoresizingMaskIntoConstraints = false
    anchorView.onHeightChange = { [weak self] _ in
      self?.invalidatePreferredLayout()
    }
    contentContainer.addSubview(anchorView)

    NSLayoutConstraint.activate([
      anchorView.topAnchor.constraint(equalTo: separatorBlurView.bottomAnchor, constant: 6),
      anchorView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
      anchorView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
      anchorView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -4),
    ])

    self.anchorView = anchorView
    invalidatePreferredLayout()
  }

  override func preferredLayoutAttributesFitting(
    _ layoutAttributes: UICollectionViewLayoutAttributes
  ) -> UICollectionViewLayoutAttributes {
    let attributes = super.preferredLayoutAttributesFitting(layoutAttributes)
    let targetSize = CGSize(
      width: layoutAttributes.frame.width,
      height: UIView.layoutFittingCompressedSize.height
    )

    let fittedSize = systemLayoutSizeFitting(
      targetSize,
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )

    attributes.frame.size.height = ceil(fittedSize.height)
    return attributes
  }

  private func invalidatePreferredLayout() {
    setNeedsLayout()
    layoutIfNeeded()
    collectionView()?.collectionViewLayout.invalidateLayout()
  }

  private func collectionView() -> UICollectionView? {
    var view: UIView? = superview
    while let currentView = view {
      if let collectionView = currentView as? UICollectionView {
        return collectionView
      }
      view = currentView.superview
    }
    return nil
  }
}
