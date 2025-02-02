import AppKit
import Foundation
import SwiftUI

// System colors: https://gist.github.com/andrejilderda/8677c565cddc969e6aae7df48622d47c

enum Theme {
  // MARK: - General

  static let pageBackgroundMaterial: NSVisualEffectView.Material = .contentBackground
  static let whiteOnLight: NSColor = .init(name: "whiteOrBlack") { appearance in
    appearance.name == .darkAqua ? NSColor.black : NSColor.white
  }

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
  static let sidebarItemRadius: CGFloat = 10
  static let sidebarItemPadding: CGFloat = 8
  static let sidebarItemSpacing: CGFloat = 1
  static let sidebarTopItemFont: Font = .body.weight(.regular)
  static let sidebarTopItemHeight: CGFloat = 24

  // MARK: - Message View

  static let messageMaxWidth: CGFloat = 420
  static let messageOuterVerticalPadding: CGFloat = 2.0 // gap between consequetive messages
  static let messageSidePadding: CGFloat = 20.0
  static let messageAvatarSize: CGFloat = 28
  // between avatar and content
  static let messageHorizontalStackSpacing: CGFloat = 8.0
  // between name and text
  static let messageVerticalStackSpacing: CGFloat = 0.0
  static let messageNameLabelHeight: CGFloat = 16
  static let messageTextFont: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
  static let messageTextLineFragmentPadding: CGFloat = 0
  static let messageTextContainerInset: NSSize = .zero
  static let messageTextViewPadding: CGFloat = 0
  static let messageContentViewSpacing: CGFloat = 8.0

  // MARK: - Chat View

  static let chatViewMinWidth: CGFloat = 315 // going below this makes media calcs mess up
  static let messageGroupSpacing: CGFloat = 8
  static let messageListTopInset: CGFloat = 14
  static let messageListBottomInset: CGFloat = 10
  static let embeddedMessageHeight: CGFloat = 34.0

  static let composeMinHeight: CGFloat = 44
  static let composeButtonSize: CGFloat = 24
  static let composeTextViewHorizontalPadding: CGFloat = 10.0
  static let composeVerticalPadding: CGFloat = 2.0 // inner, higher makes 2 line compose increase height
  static let composeOuterSpacing: CGFloat = 18 // horizontal
  static let composeOutlineColor: NSColor = .init(name: "composeOutlineColor") { appearance in
    appearance.name == .darkAqua ? NSColor.white
      .withAlphaComponent(0.1) : NSColor.black
      .withAlphaComponent(0.09)
  }
  

  // MARK: - Devtools

  static let devtoolsHeight: CGFloat = 30
}
