import Auth
import InlineKit
import UIKit

class ReactionsFlowView: UIView {
  // MARK: - Properties

  var horizontalSpacing: CGFloat = 4
  var verticalSpacing: CGFloat = 4
  private var outgoing: Bool = false

  private var containerStackView: UIStackView!
  private var reactionViews = [String: MessageReactionView]()

  var onReactionTap: ((String) -> Void)?

  // MARK: - Initialization

  init(outgoing: Bool) {
    self.outgoing = outgoing
    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear

    containerStackView = UIStackView()
    containerStackView.axis = .vertical
    containerStackView.spacing = verticalSpacing
    containerStackView.alignment = .leading
    containerStackView.distribution = .fill
    containerStackView.translatesAutoresizingMaskIntoConstraints = false

    addSubview(containerStackView)

    NSLayoutConstraint.activate([
      containerStackView.topAnchor.constraint(equalTo: topAnchor),
      containerStackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      containerStackView.trailingAnchor.constraint(equalTo: trailingAnchor),
      containerStackView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  // MARK: - Public Methods

  func configure(with reactions: [(emoji: String, count: Int, userIds: [Int64])], animatedEmoji: String? = nil) {
    // Create a dictionary of new reactions
    let newReactions = reactions.reduce(into: [String: (count: Int, userIds: [Int64])]()) {
      $0[$1.emoji] = ($1.count, $1.userIds)
    }

    // Find reactions to remove and add
    let currentEmojis = Set(reactionViews.keys)
    let newEmojis = Set(newReactions.keys)
    let removedEmojis = currentEmojis.subtracting(newEmojis)
    let addedEmojis = newEmojis.subtracting(currentEmojis)

    // Store views that need animation
    var viewsToRemove: [(view: UIView, originalFrame: CGRect)] = []
    var viewsToAdd: [MessageReactionView] = []

    // Process removals - collect views to animate later
    for emoji in removedEmojis {
      guard let view = reactionViews[emoji] else { continue }

      // Store original position for animation
      let originalFrame = view.convert(view.bounds, to: self)
      
      // Only animate if this is the specific emoji being removed
      if emoji == animatedEmoji {
        viewsToRemove.append((view: view, originalFrame: originalFrame))
      }

      // Remove from dictionary
      reactionViews.removeValue(forKey: emoji)
    }

    // Create new views but don't add to layout yet
    for reaction in reactions {
      if addedEmojis.contains(reaction.emoji) {
        let byCurrentUser = reaction.userIds.contains(Auth.shared.getCurrentUserId() ?? 0)
        let view = MessageReactionView(
          emoji: reaction.emoji,
          count: reaction.count,
          byCurrentUser: byCurrentUser,
          outgoing: outgoing
        )

        view.onTap = { [weak self] emoji in
          self?.onReactionTap?(emoji)
        }

        reactionViews[reaction.emoji] = view
        
        // Only animate if this is the specific emoji being added
        if reaction.emoji == animatedEmoji {
          viewsToAdd.append(view)
        }
      }
    }

    // Update existing reactions
    for (emoji, view) in reactionViews {
      if let newCount = newReactions[emoji]?.count, newCount != view.count {
        // Animate count change only for the specific emoji
        view.updateCount(newCount, animated: emoji == animatedEmoji)
      }
    }

    // Disable animations temporarily for layout rebuild
    UIView.performWithoutAnimation {
      // Clear and rebuild the entire layout
      rebuildLayout(with: Array(reactionViews.values))
    }

    // Now animate removals using snapshots
    for (view, originalFrame) in viewsToRemove {
      let snapshot = view.snapshotView(afterScreenUpdates: true) ?? UIView()
      snapshot.frame = originalFrame
      addSubview(snapshot)

      UIView.animate(withDuration: 0.2, animations: {
        snapshot.alpha = 0
        snapshot.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
      }) { _ in
        snapshot.removeFromSuperview()
      }
    }

    // Animate additions
    for view in viewsToAdd {
      view.alpha = 0
      view.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)

      UIView.animate(withDuration: 0.3, delay: 0.1, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.5) {
        view.alpha = 1
        view.transform = .identity
      }
    }
  }

  // MARK: - Private Methods

  private func rebuildLayout(with views: [MessageReactionView]) {
    // Remove all existing rows
    for arrangedSubview in containerStackView.arrangedSubviews {
      containerStackView.removeArrangedSubview(arrangedSubview)
      arrangedSubview.removeFromSuperview()
    }

    // Sort views to maintain consistent order
    let sortedViews = views.sorted { $0.emoji < $1.emoji }

    var currentRow: UIStackView?
    var currentRowWidth: CGFloat = 0
    let maxWidth = UIScreen.main.bounds.width * 0.7

    for view in sortedViews {
      let viewWidth = view.sizeThatFits(CGSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
      )).width

      if currentRow == nil || currentRowWidth + viewWidth + horizontalSpacing > maxWidth {
        currentRow = UIStackView()
        currentRow!.axis = .horizontal
        currentRow!.spacing = horizontalSpacing
        currentRow!.alignment = .center
        containerStackView.addArrangedSubview(currentRow!)
        currentRowWidth = 0
      }

      currentRow!.addArrangedSubview(view)
      currentRowWidth += viewWidth + horizontalSpacing
    }

    // Force layout update
    layoutIfNeeded()
  }
}
