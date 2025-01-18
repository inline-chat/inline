import InlineKit
import UIKit

class MessageCollectionViewCell: UICollectionViewCell {
  static let reuseIdentifier = "MessageCell"
  private var messageView: UIMessageView?
  var fromOtherSender: Bool = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    // Set content view priorities to allow proper sizing
    contentView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    contentView.setContentHuggingPriority(.defaultLow, for: .horizontal)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

//  override func prepareForReuse() {
//    super.prepareForReuse()
//    print("Cell being reused - clearing message view")
//    messageView?.removeFromSuperview()
//    messageView = nil
//  }

  func configure(with message: FullMessage, fromOtherSender: Bool) {
    messageView?.removeFromSuperview()

    let newMessageView = UIMessageView(fullMessage: message)
    newMessageView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(newMessageView)

    NSLayoutConstraint.activate([
      newMessageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      newMessageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      newMessageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: fromOtherSender ? 12 : 2),
      newMessageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: 0),
    ])

    messageView = newMessageView
    contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
  }

  override func preferredLayoutAttributesFitting(
    _ layoutAttributes: UICollectionViewLayoutAttributes
  ) -> UICollectionViewLayoutAttributes {
    let attributes = super.preferredLayoutAttributesFitting(layoutAttributes)
    layoutIfNeeded()

    let targetSize = CGSize(
      width: layoutAttributes.frame.width,
      height: UIView.layoutFittingCompressedSize.height
    )

    let size = contentView.systemLayoutSizeFitting(
      targetSize,
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )

    attributes.frame.size = size
    return attributes
  }
}
