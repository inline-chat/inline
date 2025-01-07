import AppKit
import InlineKit
import InlineUI
import SwiftUI

class UserAvatarView: NSView {
  private var user: User?
  
  private var hostingView: NSHostingView<UserAvatar>?
  
  init(user: User) {
    self.user = user
    super.init(frame: NSRect(x: 0, y: 0, width: Theme.messageAvatarSize, height: Theme.messageAvatarSize))
    updateAvatar()
  }
  
  func setUser(_ user: User) {
    self.user = user
    updateAvatar()
  }
    
  override init(frame: NSRect) {
    super.init(frame: frame)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }
  
  private func updateAvatar() {
    guard let user = user else { return }

    let swiftUIView = UserAvatar(user: user, size: Theme.messageAvatarSize, ignoresSafeArea: true)
    hostingView = NSHostingView(rootView: swiftUIView)
    
    guard let hostingView = hostingView else { return } // happy type check?
    
    hostingView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hostingView)
      
    NSLayoutConstraint.activate([
      hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
      hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
      hostingView.topAnchor.constraint(equalTo: topAnchor),
      hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
  }
}
