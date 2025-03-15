import AppKit
import Cocoa
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
  static let sidebarItemPadding: CGFloat = 7.0
  // extra to above padding. note: weird thing is making this 3.0 fucks up home sidebar.
  static let sidebarItemLeadingGutter: CGFloat = 4.0
  static let sidebarItemSpacing: CGFloat = 1
  static let sidebarTopItemFont: Font = .body.weight(.regular)
  static let sidebarTopItemHeight: CGFloat = 24

  // MARK: - Message View

  static let messageMaxWidth: CGFloat = 420
  static let messageOuterVerticalPadding: CGFloat = 1.0 // gap between consequetive messages
  static let messageSidePadding: CGFloat = 20.0
  static let messageAvatarSize: CGFloat = 28
  // between avatar and content
  static let messageHorizontalStackSpacing: CGFloat = 8.0
  static let messageNameLabelHeight: CGFloat = 16
  static let messageTextFont: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
  static let messageTextLineFragmentPadding: CGFloat = 0
  static let messageTextContainerInset: NSSize = .zero
  static let messageTextViewPadding: CGFloat = 0
  static let messageContentViewSpacing: CGFloat = 8.0
  static var messageRowMaxWidth: CGFloat {
    Theme.messageMaxWidth + Theme.messageAvatarSize + Theme.messageSidePadding + Theme
      .messageHorizontalStackSpacing + Theme.messageRowSafeAreaInset
  }

  // - after bubble -
  static let messageBubblePrimaryBgColor: NSColor = .init(name: "messageBubblePrimaryBgColor") { appearance in
    appearance.name == .darkAqua ? NSColor(
      calibratedRed: 120 / 255,
      green: 94 / 255,
      blue: 212 / 255,
      alpha: 1.0
    ) : NSColor(
      calibratedRed: 143 / 255,
      green: 116 / 255,
      blue: 238 / 255,
      alpha: 1.0
    )
  }

  static let messageBubbleSecondaryBgColor: NSColor = .init(name: "messageBubbleSecondaryBgColor") { appearance in
    appearance.name == .darkAqua ? NSColor.white
      .withAlphaComponent(0.1) : .init(
        calibratedRed: 236 / 255,
        green: 236 / 255,
        blue: 236 / 255,
        alpha: 1.0
      )
  }

  /// used for bubbles diff to edge
  static let messageRowSafeAreaInset: CGFloat = 50.0
  static let messageBubbleContentHorizontalInset: CGFloat = 11.0
  static let messageSingleLineTextOnlyHeight: CGFloat = 28.0
  static let messageBubbleCornerRadius: CGFloat = 14.0
  static let messageTimeHeight: CGFloat = 13.0
  static let messageTextOnlyVerticalInsets: CGFloat = 6.0
  static let messageTextAndPhotoSpacing: CGFloat = 10.0
  static let messageTextAndTimeSpacing: CGFloat = 0.0
  static let messageOutgoingTimeWidth: CGFloat = 48.0
  static let messageIncomingTimeWidth: CGFloat = 38.0

  // MARK: - Chat View

  static let chatToolbarIconSize: CGFloat = 32
  static let chatViewMinWidth: CGFloat = 315 // going below this makes media calcs mess up
  static let messageGroupSpacing: CGFloat = 8
  static let messageListTopInset: CGFloat = 14
  static let messageListBottomInset: CGFloat = 10
  static let embeddedMessageHeight: CGFloat = 40.0
  static let documentViewHeight: CGFloat = 36.0
  static let scrollButtonSize: CGFloat = 32.0

  static let composeMinHeight: CGFloat = 44
  static let composeAttachmentsVPadding: CGFloat = 6
  static let composeAttachmentImageHeight: CGFloat = 80
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
