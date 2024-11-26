import AppKit
import InlineKit
import InlineUI
import SwiftUI

class UserAvatarView: NSView {
  var prevUser: User?
  var user: User? {
    didSet {
      updateAvatar()
    }
  }
  
  private var hostingController: NSHostingController<UserAvatar>?
  
  init(user: User) {
    self.user = user
    super.init(frame: .zero)
  }
  
  override init(frame: NSRect) {
    super.init(frame: frame)
  }
  
  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }
  
  private func updateAvatar() {
    guard let user = user else { return }
    if let hostingController = hostingController {
      if user != prevUser {
        let swiftUIView = UserAvatar(user: user, size: Theme.messageAvatarSize)
        hostingController.rootView = swiftUIView
      }
    } else {
      let swiftUIView = UserAvatar(user: user, size: Theme.messageAvatarSize)
      hostingController = NSHostingController(rootView: swiftUIView)
      
      if let hostView = hostingController?.view {
        hostView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostView)
        
        NSLayoutConstraint.activate([
          hostView.leadingAnchor.constraint(equalTo: leadingAnchor),
          hostView.trailingAnchor.constraint(equalTo: trailingAnchor),
          hostView.topAnchor.constraint(equalTo: topAnchor),
          hostView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
      }
    }
    
    prevUser = user
  }
}
