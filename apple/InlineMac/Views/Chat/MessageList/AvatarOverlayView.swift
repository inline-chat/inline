//import AppKit
//import InlineKit
//import SwiftUI
//
//class AvatarOverlayView: NSView {
//  var avatarViews: [Int: UserAvatarView] = [:]
//  static let size: CGFloat = Theme.messageAvatarSize
//  private let topPadding: CGFloat = Theme.messageVerticalPadding
//  private let topEdgeInset: CGFloat = Theme.messageListTopInset
//  
//  override init(frame: NSRect) {
//    super.init(frame: frame)
//    // This helped
//    wantsLayer = true
//    clipsToBounds = true
//    translatesAutoresizingMaskIntoConstraints = false
//  }
//  
//  @available(*, unavailable)
//  required init?(coder: NSCoder) {
//    fatalError("init(coder:) has not been implemented")
//  }
//  
//  func updateAvatar(for row: Int, user: User, yOffset: CGFloat, animated: Bool = true) {
//    let avatarView = avatarViews[row] ?? createAvatarView(for: user)
//    avatarViews[row] = avatarView
//    
//    let frame = NSRect(
//      x: 0,
//      y: yOffset,
//      width: Self.size,
//      height: Self.size
//    )
//    
//    avatarView.frame = frame
//  }
//  
//  private func createAvatarView(for user: User) -> UserAvatarView {
//    NSAnimationContext.beginGrouping()
//    NSAnimationContext.current.duration = 0
//    let avatarView = UserAvatarView(user: user)
//    
//    addSubview(avatarView)
//    NSAnimationContext.endGrouping()
//    
//    return avatarView
//  }
//  
//  func removeAvatar(for row: Int) {
//    NSAnimationContext.beginGrouping()
//    NSAnimationContext.current.duration = 0
//    
//    avatarViews[row]?.removeFromSuperview()
//    avatarViews.removeValue(forKey: row)
//    
//    NSAnimationContext.endGrouping()
//  }
//  
//  func clearAvatars() {
//    avatarViews.values.forEach { $0.removeFromSuperview() }
//    avatarViews.removeAll()
//  }
//}
