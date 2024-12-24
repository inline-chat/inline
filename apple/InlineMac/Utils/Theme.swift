import AppKit
import Foundation
import SwiftUI

enum Theme {
  // MARK: - General

  // MARK: - Window

  static let windowMinimumSize: CGSize = .init(width: 320, height: 300)

  // MARK: - Main View & Split View

  static let collapseSidebarAtWindowSize: CGFloat = 500

  // MARK: - Sidebar

  /// 190 is minimum that fits both sidebar collapse button and plus button
  static let minimumSidebarWidth: CGFloat = 200
  static let idealSidebarWidth: CGFloat = 240
  static let sidebarIconSize: CGFloat = 22
  static let sidebarItemHeight: CGFloat = 28
  static let sidebarIconSpacing: CGFloat = 6
  static let sidebarItemRadius: CGFloat = 6
  static let sidebarItemPadding: CGFloat = 8
  static let sidebarTopItemFont: Font = Font.body.weight(.medium)
  static let sidebarTopItemHeight: CGFloat = 30

  // MARK: - Message View

  static let messageSidePadding: CGFloat = 14
  static let messageVerticalPadding: CGFloat = 1.0
  static let messageAvatarSize: CGFloat = 28
//  Space between avatar and content
  static let messageHorizontalStackSpacing: CGFloat = 8
  static let messageVerticalStackSpacing: CGFloat = 2.0
  static let messageNameLabelHeight: CGFloat = 16
  static let messageTextFont: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
  static let messageSenderFont: NSFont = .systemFont(
    ofSize: NSFont.systemFontSize,
    weight: .semibold
  )
  static let messageTextLineFragmentPadding: CGFloat = 0
  static let messageTextContainerInset: NSSize = .zero
  static let messageTextViewPadding: CGFloat = 0
  static let messageBubblePadding: CGSize = .init(width: 8.0, height: 4.0)
  static let messageIsBubble: Bool = true
  static let messageBubbleLightColor: NSColor = NSColor(calibratedRed: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)
  static let messageBubbleDarkColor: NSColor = NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
  static let messageBubbleColor: NSColor = NSColor(name: "messageBubbleColor") { appearance in
    appearance.name == .darkAqua ? Self.messageBubbleDarkColor : Self.messageBubbleLightColor
  }
  static let messageBubbleOutgoingColor: NSColor = .systemBlue.highlight(
    withLevel: 0.1
  ) ?? .systemBlue

  static let messageBubbleMinWidth: CGFloat = 12.0

  // MARK: - Chat View

  static let messageGroupSpacing: CGFloat = 8
  static let messageListTopInset: CGFloat = 14
  static let messageListBottomInset: CGFloat = 10
  
  static let composeMinHeight: CGFloat = 44
  static let composeVerticalPadding: CGFloat = 8
}
