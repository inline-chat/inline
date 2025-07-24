import Auth
import InlineKit
import UIKit

// Import ReactionUser from MessageReactionView
// Note: ReactionUser is defined in MessageReactionView.swift

class ReactionsFlowView: UIView {
  // MARK: - Properties

  var horizontalSpacing: CGFloat = 4
  var verticalSpacing: CGFloat = 4
  private var outgoing: Bool = false

  private var reactionViews = [String: MessageReactionView]()
  private var reactionFrames = [String: CGRect]()
  private var totalHeight: CGFloat = 0
  private var cachedViewSizes = [String: CGSize]()
  private var lastLayoutWidth: CGFloat = 0

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
  }

  // MARK: - Public Methods

  func configure(
    with groupedReactions: [GroupedReaction],
    animatedEmoji: String? = nil
  ) {
    // Create a dictionary of new reactions from GroupedReaction
    let newReactions = groupedReactions.reduce(into: [String: GroupedReaction]()) {
      $0[$1.emoji] = $1
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
      let originalFrame = view.frame

      // Only animate if this is the specific emoji being removed
      if emoji == animatedEmoji {
        viewsToRemove.append((view: view, originalFrame: originalFrame))
      }

      // Remove from dictionary
      reactionViews.removeValue(forKey: emoji)
    }

    // Create new views but don't add to layout yet
    for groupedReaction in groupedReactions {
      if addedEmojis.contains(groupedReaction.emoji) {
        let userIds = groupedReaction.reactions.map(\.reaction.userId)
        let byCurrentUser = userIds.contains(Auth.shared.getCurrentUserId() ?? 0)

        // Create ReactionUser objects from FullReaction
        let reactionUsers = groupedReaction.reactions.map { fullReaction in
          ReactionUser(userId: fullReaction.reaction.userId, userInfo: fullReaction.userInfo)
        }

        let view = MessageReactionView(
          emoji: groupedReaction.emoji,
          count: groupedReaction.reactions.count,
          byCurrentUser: byCurrentUser,
          outgoing: outgoing,
          reactionUsers: reactionUsers
        )

        view.onTap = { [weak self] emoji in
          self?.onReactionTap?(emoji)
        }

        reactionViews[groupedReaction.emoji] = view

        // Only animate if this is the specific emoji being added
        if groupedReaction.emoji == animatedEmoji {
          viewsToAdd.append(view)
        }
      }
    }

    // Update existing reactions
    for (emoji, view) in reactionViews {
      if let groupedReaction = newReactions[emoji] {
        let newCount = groupedReaction.reactions.count
        let userIds = groupedReaction.reactions.map(\.reaction.userId)

        // Update count if changed
        if newCount != view.count {
          view.updateCount(newCount, animated: emoji == animatedEmoji)
        }

        // Update user information
        let reactionUsers = groupedReaction.reactions.map { fullReaction in
          ReactionUser(userId: fullReaction.reaction.userId, userInfo: fullReaction.userInfo)
        }
        view.updateReactionUsers(reactionUsers)
      }
    }

    // Disable animations temporarily for layout rebuild
    UIView.performWithoutAnimation {
      // Clear and rebuild the entire layout only if there are structural changes
      if !removedEmojis.isEmpty || !addedEmojis.isEmpty {
        rebuildLayout(with: Array(reactionViews.values))
      }
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

    // Animate additions with proper positioning
    for view in viewsToAdd {
      if let finalFrame = reactionFrames[view.emoji] {
        view.frame = finalFrame
        view.alpha = 0
        view.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)

        UIView.animate(withDuration: 0.3, delay: 0.1, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.5) {
          view.alpha = 1
          view.transform = .identity
        }
      }
    }
    
    // Animate existing views to their new positions if layout changed
    animateExistingViewsToNewPositions(excludingAnimated: animatedEmoji)
  }

  // MARK: - Private Methods
  
  private func animateExistingViewsToNewPositions(excludingAnimated animatedEmoji: String?) {
    // Store current positions before layout
    var currentFrames: [String: CGRect] = [:]
    for (emoji, view) in reactionViews {
      if emoji != animatedEmoji {
        currentFrames[emoji] = view.frame
      }
    }
    
    // Animate views that changed position
    for (emoji, view) in reactionViews {
      guard emoji != animatedEmoji,
            let currentFrame = currentFrames[emoji],
            let newFrame = reactionFrames[emoji],
            !currentFrame.equalTo(newFrame) else { continue }
      
      // Animate from current position to new position
      UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut], animations: {
        view.frame = newFrame
      })
    }
  }

  private func rebuildLayout(with views: [MessageReactionView]) {
    // Remove all views from superview
    subviews.forEach { $0.removeFromSuperview() }
    
    // Clear cached frames and sizes for removed reactions
    reactionFrames.removeAll()
    
    // Clean up cached sizes for reactions that no longer exist
    let currentEmojis = Set(views.map { $0.emoji })
    cachedViewSizes = cachedViewSizes.filter { currentEmojis.contains($0.key) }
    
    // Sort views to maintain consistent order
    let sortedViews = views.sorted { $0.emoji < $1.emoji }
    
    // Calculate layout positions
    let layoutResult = calculateLayout(for: sortedViews)
    
    // Add views back and set their frames
    for view in sortedViews {
      addSubview(view)
      if let frame = reactionFrames[view.emoji] {
        view.frame = frame
      }
    }
    
    // Update our intrinsic height
    totalHeight = layoutResult.totalHeight
    
    // Invalidate intrinsic content size
    invalidateIntrinsicContentSize()
  }
  
  private func calculateLayout(for views: [MessageReactionView]) -> (totalHeight: CGFloat, rows: [[MessageReactionView]]) {
    guard !views.isEmpty else { return (0, []) }
    
    // Use a generous max width to allow reactions to expand naturally
    let maxWidth = bounds.width > 0 ? max(bounds.width, UIScreen.main.bounds.width * 0.8) : UIScreen.main.bounds.width * 0.8
    lastLayoutWidth = maxWidth
    
    var rows: [[MessageReactionView]] = []
    var currentRow: [MessageReactionView] = []
    var currentRowWidth: CGFloat = 0
    
    for view in views {
      // Use cached size or calculate and cache
      let viewSize: CGSize
      if let cachedSize = cachedViewSizes[view.emoji] {
        viewSize = cachedSize
      } else {
        viewSize = view.sizeThatFits(CGSize(
          width: CGFloat.greatestFiniteMagnitude,
          height: CGFloat.greatestFiniteMagnitude
        ))
        cachedViewSizes[view.emoji] = viewSize
      }
      
      let requiredWidth = currentRowWidth + viewSize.width + (currentRow.isEmpty ? 0 : horizontalSpacing)
      
      // Check if we need to wrap to next row
      if !currentRow.isEmpty && requiredWidth > maxWidth {
        // Finish current row
        rows.append(currentRow)
        currentRow = [view]
        currentRowWidth = viewSize.width
      } else {
        // Add to current row
        currentRow.append(view)
        currentRowWidth = requiredWidth
      }
    }
    
    // Add the last row if not empty
    if !currentRow.isEmpty {
      rows.append(currentRow)
    }
    
    // Calculate positions for each view
    var yOffset: CGFloat = 0
    
    for (rowIndex, row) in rows.enumerated() {
      var xOffset: CGFloat = 0
      
      // Use cached sizes for row height calculation
      let rowHeight = row.compactMap { view in
        cachedViewSizes[view.emoji]?.height
      }.max() ?? 0
      
      for view in row {
        guard let viewSize = cachedViewSizes[view.emoji] else { continue }
        
        // Center vertically within the row
        let yPosition = yOffset + (rowHeight - viewSize.height) / 2
        
        reactionFrames[view.emoji] = CGRect(
          x: xOffset,
          y: yPosition,
          width: viewSize.width,
          height: viewSize.height
        )
        
        xOffset += viewSize.width + horizontalSpacing
      }
      
      yOffset += rowHeight
      if rowIndex < rows.count - 1 {
        yOffset += verticalSpacing
      }
    }
    
    let finalHeight = yOffset
    return (finalHeight, rows)
  }
  
  override var intrinsicContentSize: CGSize {
    let maxRowWidth = calculateMaxRowWidth()
    return CGSize(width: maxRowWidth, height: totalHeight)
  }
  
  private func calculateMaxRowWidth() -> CGFloat {
    guard !reactionViews.isEmpty else { return 0 }
    
    let views = Array(reactionViews.values).sorted { $0.emoji < $1.emoji }
    var maxWidth: CGFloat = 0
    var currentRowWidth: CGFloat = 0
    
    // First, try to fit all reactions on one row
    var totalWidthSingleRow: CGFloat = 0
    for (index, view) in views.enumerated() {
      let viewSize: CGSize
      if let cachedSize = cachedViewSizes[view.emoji] {  
        viewSize = cachedSize
      } else {
        viewSize = view.sizeThatFits(CGSize(
          width: CGFloat.greatestFiniteMagnitude,
          height: CGFloat.greatestFiniteMagnitude
        ))
        cachedViewSizes[view.emoji] = viewSize
      }
      
      totalWidthSingleRow += viewSize.width
      if index > 0 {
        totalWidthSingleRow += horizontalSpacing
      }
    }
    
    // Check if single row fits within reasonable bounds (80% of screen width)
    let maxReasonableWidth = UIScreen.main.bounds.width * 0.8
    if totalWidthSingleRow <= maxReasonableWidth {
      return totalWidthSingleRow
    }
    
    // Otherwise, calculate with wrapping
    let availableWidth = maxReasonableWidth
    currentRowWidth = 0
    
    for view in views {
      let viewSize = cachedViewSizes[view.emoji] ?? CGSize.zero
      let requiredWidth = currentRowWidth + viewSize.width + (currentRowWidth > 0 ? horizontalSpacing : 0)
      
      if currentRowWidth > 0 && requiredWidth > availableWidth {
        // End current row and start new one
        maxWidth = max(maxWidth, currentRowWidth)
        currentRowWidth = viewSize.width
      } else {
        currentRowWidth = requiredWidth
      }
    }
    
    maxWidth = max(maxWidth, currentRowWidth)
    return maxWidth
  }
  
  override func sizeThatFits(_ size: CGSize) -> CGSize {
    guard !reactionViews.isEmpty else { return CGSize.zero }
    
    // Calculate the actual required width and height
    let maxRowWidth = calculateMaxRowWidth()
    
    // Temporarily set bounds to calculate layout  
    let originalBounds = bounds
    bounds = CGRect(origin: bounds.origin, size: CGSize(width: maxRowWidth, height: size.height))
    
    let layoutResult = calculateLayout(for: Array(reactionViews.values).sorted { $0.emoji < $1.emoji })
    
    // Restore original bounds
    bounds = originalBounds
    
    return CGSize(width: maxRowWidth, height: layoutResult.totalHeight)
  }
  
  override func layoutSubviews() {
    super.layoutSubviews()
    
    // Only recalculate if our width has changed significantly
    let currentWidth = bounds.width
    let widthChanged = abs(currentWidth - lastLayoutWidth) > 1.0
    
    if widthChanged && currentWidth > 0 && !reactionViews.isEmpty {
      // Store current positions for smooth animation
      let previousFrames = reactionFrames
      
      // Recalculate layout
      let sortedViews = Array(reactionViews.values).sorted { $0.emoji < $1.emoji }
      let layoutResult = calculateLayout(for: sortedViews)
      
      // Animate views to new positions
      for view in sortedViews {
        let emoji = view.emoji
        guard let newFrame = reactionFrames[emoji] else { continue }
        
        if let previousFrame = previousFrames[emoji], !previousFrame.equalTo(newFrame) {
          UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut], animations: {
            view.frame = newFrame
          })
        } else {
          view.frame = newFrame
        }
      }
      
      // Update total height and invalidate
      totalHeight = layoutResult.totalHeight
      invalidateIntrinsicContentSize()
    }
  }
}
