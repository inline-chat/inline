import InlineKit
import InlineUI
import SwiftUI
import UIKit

class MessageCollectionViewCell: UICollectionViewCell {
  static let reuseIdentifier = "MessageCell"
  private var messageView: UIMessageView?
  private var avatarHostingController: UIHostingController<UserAvatar>?
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

  lazy var nameLabel: UILabel = {
    var label = UILabel()
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.textColor = .secondaryLabel
    label.translatesAutoresizingMaskIntoConstraints = false

    return label
  }()

  func configure(with message: FullMessage, fromOtherSender: Bool) {
    var isThread: Bool {
      message.peerId.isThread
    }
    var outgoing: Bool {
      message.message.out == true
    }

    nameLabel.text = message.from?.firstName ?? "USER"
    // Clean up previous state first
    messageView?.removeFromSuperview()
    nameLabel.removeFromSuperview()
    avatarHostingController?.view.removeFromSuperview()
    avatarHostingController = nil

    if isThread, fromOtherSender {
      contentView.addSubview(nameLabel)

      // Add avatar if we have user info
      if let from = message.from {
        let avatar = UserAvatar(user: from, size: 26)
        let hostingController = UIHostingController(rootView: avatar)
        avatarHostingController = hostingController
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hostingController.view)

        var constraints = [
          hostingController.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
          hostingController.view.widthAnchor.constraint(equalToConstant: 26),
          hostingController.view.heightAnchor.constraint(equalToConstant: 26),
        ]

        if outgoing {
          constraints.append(hostingController.view.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor,
            constant: -2
          ))
        } else {
          constraints.append(hostingController.view.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor,
            constant: 2
          ))
        }

        NSLayoutConstraint.activate(constraints)
      }

      var constraints = [
        nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
        nameLabel.heightAnchor.constraint(equalToConstant: 16),
      ]

      if outgoing {
        constraints.append(nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -42))
      } else {
        constraints.append(nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 42))
      }

      NSLayoutConstraint.activate(constraints)
    }

    let newMessageView = UIMessageView(fullMessage: message)
    newMessageView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(newMessageView)

    let topConstraint: NSLayoutConstraint = if isThread, fromOtherSender {
      newMessageView.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2)
    } else {
      newMessageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: fromOtherSender ? 12 : 2)
    }

    let leadingConstraint: NSLayoutConstraint = if isThread {
      if outgoing {
        newMessageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 26)
      } else if fromOtherSender, let avatarView = avatarHostingController?.view {
        newMessageView.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: -2)
      } else {
        newMessageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 26)
      }
    } else {
      newMessageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
    }

    let trailingConstraint: NSLayoutConstraint = if isThread {
      if outgoing, let avatarView = avatarHostingController?.view {
        newMessageView.trailingAnchor.constraint(equalTo: avatarView.leadingAnchor, constant: 2)
      } else {
        newMessageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -26)
      }
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
