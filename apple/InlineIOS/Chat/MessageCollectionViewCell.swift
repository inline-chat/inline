import InlineKit
import InlineUI
import SwiftUI
import UIKit

class MessageCollectionViewCell: UICollectionViewCell {
  static let reuseIdentifier = "MessageCell"

  var messageView: UIMessageView?
  var avatarHostingController: UIHostingController<UserAvatar>?

  var isThread: Bool = false
  var outgoing: Bool = false
  var fromOtherSender: Bool = false
  var message: FullMessage!
  var spaceId: Int64 = 0

  lazy var nameLabel: UILabel = {
    var label = UILabel()
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.textColor = .secondaryLabel
    label.translatesAutoresizingMaskIntoConstraints = false

    return label
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupContentSize()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(with message: FullMessage, fromOtherSender: Bool, spaceId: Int64) {
    isThread = message.peerId.isThread
    outgoing = message.message.out == true
    self.message = message
    self.fromOtherSender = fromOtherSender
    self.spaceId = spaceId
    nameLabel.text = message.from?.firstName ?? "USER"

    resetCell()

    setupIncomingThreadMessage()
    setupBaseMessageConstraints()

    contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    resetCell()
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

extension MessageCollectionViewCell {
  func setupContentSize() {
    contentView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    contentView.setContentHuggingPriority(.defaultLow, for: .horizontal)
  }

  func setupBaseMessageConstraints() {
    let newMessageView = UIMessageView(fullMessage: message, spaceId: spaceId)
    newMessageView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(newMessageView)

    let topConstraint: NSLayoutConstraint = if isThread, fromOtherSender, !outgoing {
      newMessageView.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2)
    } else {
      newMessageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: fromOtherSender ? 12 : 2)
    }

    let leadingConstraint: NSLayoutConstraint = if isThread, !outgoing {
      if fromOtherSender, let avatarView = avatarHostingController?.view {
        newMessageView.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: -2)
      } else {
        newMessageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32)
      }
    } else {
      newMessageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
    }

    let trailingConstraint: NSLayoutConstraint = if isThread, !outgoing {
      newMessageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32)
    } else {
      newMessageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
    }
    NSLayoutConstraint.activate([
      leadingConstraint,
      trailingConstraint,
      topConstraint,
      newMessageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])

    messageView = newMessageView
  }

  func setupIncomingThreadMessage() {
    if isThread, fromOtherSender, !outgoing {
      contentView.addSubview(nameLabel)

      // Add avatar if we have user info
      if let from = message.senderInfo {
        let avatar = UserAvatar(userInfo: from, size: 32)
        let hostingController = UIHostingController(rootView: avatar)
        avatarHostingController = hostingController
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hostingController.view)

        NSLayoutConstraint.activate([
          hostingController.view.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 34),
          hostingController.view.widthAnchor.constraint(equalToConstant: 32),
          hostingController.view.heightAnchor.constraint(equalToConstant: 32),
          hostingController.view.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor,
            constant: 2
          ),
        ])
      }

      NSLayoutConstraint.activate([
        nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
        nameLabel.heightAnchor.constraint(equalToConstant: 16),
        nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 42),
      ])
    }
  }

  func resetCell() {
    messageView?.removeFromSuperview()
    nameLabel.removeFromSuperview()
    avatarHostingController?.view.removeFromSuperview()
    avatarHostingController = nil
  }
}
