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
  static let sidebarTopItemFont: Font = .body.weight(.regular)
  static let sidebarTopItemHeight: CGFloat = 30

  // MARK: - Message View

  static let messageMaxWidth: CGFloat = 420
  static let messageOuterVerticalPadding: CGFloat = 2.0 // gap between consequetive bubbles
  static let messageSidePadding: CGFloat = 14
  static let messageAvatarSize: CGFloat = 28
//  Space between avatar and content
  static let messageHorizontalStackSpacing: CGFloat = 8
  static let messageVerticalStackSpacing: CGFloat = 2.0
  static let messageNameLabelHeight: CGFloat = 14
  static let messageTextFont: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
  static let messageTextLineFragmentPadding: CGFloat = 0
  static let messageTextContainerInset: NSSize = .zero
  static let messageTextViewPadding: CGFloat = 0
  static let messageBubbleRadius: CGFloat = 15.0
//  static let messageBubblePadding: CGSize = .init(width: 12.0, height: 7.0)
  static let messageBubblePadding: CGSize = .init(width: 12.0, height: 5.0)
  static var messageIsBubble: Bool {
    AppSettings.shared.messageStyle == .bubble
  }

  static let messageBubbleLightColor: NSColor = .init(calibratedRed: 0.92, green: 0.92, blue: 0.92, alpha: 1.0)
  static let messageBubbleDarkColor: NSColor = .init(calibratedRed: 0.18, green: 0.18, blue: 0.18, alpha: 1.0)
  static let messageBubbleColor: NSColor = .init(name: "messageBubbleColor") { appearance in
    appearance.name == .darkAqua ? Self.messageBubbleDarkColor : Self.messageBubbleLightColor
  }

  static let messageBubbleOutgoingLightColor: NSColor = .systemBlue.blended(
    withFraction: 0.1,
    of: .white
  ) ?? .systemBlue
  static let messageBubbleOutgoingDarkColor: NSColor = .systemBlue
  static let messageBubbleOutgoingColor: NSColor = .init(name: "messageBubbleOutgoingColor") { appearance in
    appearance.name == .darkAqua ? Self.messageBubbleOutgoingDarkColor : Self.messageBubbleOutgoingLightColor
  }

//  static let messageBubbleOutgoingColor: NSColor = .systemBlue.highlight(
//    withLevel: 0.3
//  ) ?? .systemBlue

  static let messageBubbleMinWidth: CGFloat = 12.0

  // MARK: - Chat View

  static let chatViewMinWidth: CGFloat = 315 // going below this makes media calcs mess up
  static let messageGroupSpacing: CGFloat = 8
  static let messageListTopInset: CGFloat = 14
  static let messageListBottomInset: CGFloat = 10

  static let composeMinHeight: CGFloat = 44
  static let composeVerticalPadding: CGFloat = 4

  // MARK: - Devtools

  static let devtoolsHeight: CGFloat = 30
}
