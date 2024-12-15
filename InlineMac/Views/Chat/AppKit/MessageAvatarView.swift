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
  
//  override var wantsUpdateLayer: Bool { true }
  
  override init(frame: NSRect) {
    super.init(frame: frame)
    // Setting layer seemed to make it laggier
//     wantsLayer = true
//    avatarView.layer?.zPosition = 100
    // layer?.masksToBounds = true
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }
  
  private func updateAvatar() {
    guard let user = user else { return }
    if let hostingController = hostingController {
      if user != prevUser {
        let swiftUIView = UserAvatar(user: user, size: Theme.messageAvatarSize, ignoresSafeArea: true)
        hostingController.rootView = swiftUIView
      }
    } else {
      let swiftUIView = UserAvatar(user: user, size: Theme.messageAvatarSize, ignoresSafeArea: true)
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



//class UserAvatarView: NSView {
//  var prevUser: User?
//  var user: User? {
//    didSet {
//      updateAvatar()
//    }
//  }
//  
//  private var initialsCircleView: InitialsCircleView?
//  
//  init(user: User) {
//    self.user = user
//    super.init(frame: .zero)
//    setupView()
//  }
//  
//  override init(frame: NSRect) {
//    super.init(frame: frame)
//    setupView()
//  }
//  
//  required init?(coder: NSCoder) {
//    super.init(coder: coder)
//    setupView()
//  }
//  
//  private func setupView() {
//    wantsLayer = true
//  }
//  
//  private func updateAvatar() {
//    guard let user = user else { return }
//    
//    // Remove existing initials view if it exists
//    initialsCircleView?.removeFromSuperview()
//    
//    // Create new initials view
//    let initialsView = InitialsCircleView(
//      firstName: user.firstName ?? user.username ?? "",
//      lastName: user.lastName,
//      size: Theme.messageAvatarSize
//    )
//    
//    initialsView.translatesAutoresizingMaskIntoConstraints = false
//    addSubview(initialsView)
//    
//    NSLayoutConstraint.activate([
//      initialsView.leadingAnchor.constraint(equalTo: leadingAnchor),
//      initialsView.trailingAnchor.constraint(equalTo: trailingAnchor),
//      initialsView.topAnchor.constraint(equalTo: topAnchor),
//      initialsView.bottomAnchor.constraint(equalTo: bottomAnchor)
//    ])
//    
//    initialsCircleView = initialsView
//    prevUser = user
//  }
//}
//
//@MainActor
//public class InitialsCircleView: NSView {
//  private let firstName: String
//  private let lastName: String?
//  private let size: CGFloat
//  
//  private let colorPalette: [NSColor] = [
//    .systemPink,
//    .systemOrange,
//    .systemPurple,
//    .systemYellow,
//    .systemTeal,
//    .systemBlue,
//    .systemGreen,
//    .systemRed,
//    .systemIndigo,
//    .systemMint,
//    .systemCyan
//  ]
//  
//  public init(firstName: String, lastName: String? = nil, size: CGFloat = 32) {
//    self.firstName = firstName
//    self.lastName = lastName
//    self.size = size
//    super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
//    
//    wantsLayer = true
//    layer?.cornerRadius = size / 2
//    layer?.masksToBounds = true
//  }
//  
//  @available(*, unavailable)
//  required init?(coder: NSCoder) {
//    fatalError("init(coder:) has not been implemented")
//  }
//  
//  private var initials: String {
//    [firstName]
//      .compactMap(\.first)
//      .prefix(2)
//      .map(String.init)
//      .joined()
//      .uppercased()
//  }
//  
//  private func backgroundColor(for name: String) -> NSColor {
//    let hash = name.utf8.reduce(0) { $0 + Int($1) }
//    return colorPalette[abs(hash) % colorPalette.count]
//  }
//  
//  override public func draw(_ dirtyRect: NSRect) {
//    super.draw(dirtyRect)
//    
//    let fullName = [firstName, lastName].compactMap { $0 }.joined()
//    let baseColor = backgroundColor(for: fullName)
//    
//    // Create gradient
//    let gradient = NSGradient(colors: [
//      baseColor.blended(withFraction: 0.3, of: .white) ?? baseColor,
//      baseColor.blended(withFraction: 0.1, of: .black) ?? baseColor
//    ])
//    
//    // Draw circle with gradient
//    let circlePath = NSBezierPath(ovalIn: bounds)
//    gradient?.draw(in: circlePath, angle: 315)
//    
//    // Draw initials
//    let attributes: [NSAttributedString.Key: Any] = [
//      .foregroundColor: NSColor.white,
//      .font: NSFont.systemFont(ofSize: size * 0.55)
//    ]
//    
//    let initialsString = NSAttributedString(string: initials, attributes: attributes)
//    let stringSize = initialsString.size()
//    
//    let x = (bounds.width - stringSize.width) / 2
//    let y = (bounds.height - stringSize.height) / 2
//    
//    initialsString.draw(at: NSPoint(x: x, y: y))
//  }
//}
//
//// MARK: - Example Usage
//
//extension InitialsCircleView {
//  static func example() -> NSView {
//    let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
//    
//    let circle1 = InitialsCircleView(firstName: "John", lastName: "Doe", size: 60)
//    circle1.frame.origin = NSPoint(x: 20, y: 220)
//    
//    let circle2 = InitialsCircleView(firstName: "Alice", lastName: "Smith", size: 60)
//    circle2.frame.origin = NSPoint(x: 100, y: 220)
//    
//    let circle3 = InitialsCircleView(firstName: "Bob", lastName: "Johnson", size: 40)
//    circle3.frame.origin = NSPoint(x: 20, y: 140)
//    
//    containerView.addSubview(circle1)
//    containerView.addSubview(circle2)
//    containerView.addSubview(circle3)
//    
//    return containerView
//  }
//}
