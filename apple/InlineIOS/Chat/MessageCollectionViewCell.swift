import InlineKit
import UIKit
class MessageCollectionViewCell: UICollectionViewCell {
  static let reuseIdentifier = "MessageCell"
  private var messageView: UIMessageView?
    
  override func prepareForReuse() {
    super.prepareForReuse()
    messageView?.removeFromSuperview()
    messageView = nil
  }
    
  func configure(with message: FullMessage, topPadding: CGFloat, bottomPadding: CGFloat) {
    // Remove existing message view if any
    messageView?.removeFromSuperview()
        
    // Create and add new message view
    let newMessageView = UIMessageView(fullMessage: message)
    newMessageView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(newMessageView)
        
    NSLayoutConstraint.activate([
      newMessageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      newMessageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      newMessageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: topPadding),
      newMessageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: 0)
    ])
        
    messageView = newMessageView
        
    // Apply transform for bottom-up scrolling
    contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
  }
}
