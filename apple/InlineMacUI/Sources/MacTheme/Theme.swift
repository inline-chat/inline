import AppKit
import Cocoa
import Foundation
import SwiftUI

// System colors: https://gist.github.com/andrejilderda/8677c565cddc969e6aae7df48622d47c

public enum Theme {
  // MARK: - General

  public static let pageBackgroundMaterial: NSVisualEffectView.Material = .contentBackground
  public static let whiteOnLight: NSColor = .init(name: "whiteOrBlack") { appearance in
    appearance.name == .darkAqua ? NSColor.black : NSColor.white
  }

  // MARK: - Colors

  public static let colorIconGray: NSColor = .init(name: "colorIconGray") { appearance in
    appearance.name == .darkAqua ?
      NSColor(red: 146 / 255, green: 146 / 255, blue: 146 / 255, alpha: 1) :
      NSColor(red: 188 / 255, green: 188 / 255, blue: 188 / 255, alpha: 1)
  }

  public static let colorTitleTextGray: NSColor = .init(name: "colorTitleTextGray") { appearance in
    appearance.name == .darkAqua ?
      NSColor(red: 160 / 255, green: 160 / 255, blue: 160 / 255, alpha: 1) :
      NSColor(red: 158 / 255, green: 158 / 255, blue: 158 / 255, alpha: 1)
  }

  // MARK: - Window

  public static let windowMinimumSize: CGSize = .init(width: 320, height: 300)
  public static let windowBackgroundColor: NSColor = .init(
    "windowBackgroundColor",
    light: NSColor(red: 249 / 255, green: 251 / 255, blue: 255 / 255, alpha: 0.5),
    dark: NSColor(red: 25 / 255, green: 25 / 255, blue: 26 / 255, alpha: 0.6)
  )

  public static let windowContentBackgroundColor: NSColor = .init(
    "windowContentBackgroundColor",
    light: NSColor(red: 249 / 255, green: 249 / 255, blue: 250 / 255, alpha: 1),
    dark: NSColor(red: 15 / 255, green: 15 / 255, blue: 16 / 255, alpha: 1)
  )

  // MARK: - Main View & Split View

  public static let collapseSidebarAtWindowSize: CGFloat = 500
  public static let toolbarHeight: CGFloat = 46

  // MARK: - Tab Bar

  public static let tabBarHeight: CGFloat = 42
  public static let tabBarItemHeight: CGFloat = 36
  public static let tabBarItemInset: CGFloat = 4

  // MARK: - Main Split View

  // public static let mainSplitViewInnerPadding: CGFloat = 10
  // public static let mainSplitViewContentRadius: CGFloat = 16
  // public static let mainSplitViewInnerPadding: CGFloat = 8
  // public static let mainSplitViewContentRadius: CGFloat = 18
  public static let mainSplitViewInnerPadding: CGFloat = 5
  public static let mainSplitViewContentRadius: CGFloat = 12

  // MARK: - Sidebar

  /// 190 is minimum that fits both sidebar collapse button and plus button
  public static let minimumSidebarWidth: CGFloat = 200
  public static let idealSidebarWidth: CGFloat = 240
  public static let sidebarItemRadius: CGFloat = 10
  public static let sidebarItemPadding: CGFloat = 7.0
  // extra to above padding. note: weird thing is making this 3.0 fucks up home sidebar.
  public static let sidebarItemLeadingGutter: CGFloat = 4.0
  public static let sidebarItemSpacing: CGFloat = 1
  public static let sidebarTopItemFont: Font = .body.weight(.regular)
  public static let sidebarTopItemHeight: CGFloat = 24

  public static let sidebarIconSpacing: CGFloat = 9
  public static let sidebarTitleIconSize: CGFloat = 24
  public static let sidebarIconSize: CGFloat = 24
  public static let sidebarItemHeight: CGFloat = 34
  public static let sidebarTitleItemFont: Font = .system(size: 13.0, weight: .medium)
  public static let sidebarItemFont: Font = .system(size: 13.0, weight: .regular)
  public static let sidebarContentSideSpacing: CGFloat = 17.0 // from inner content of item to edge of sidebar
  public static let sidebarItemInnerSpacing: CGFloat =
    11.0 // from inner content of item to edge of content active/hover style
  public static let sidebarItemOuterSpacing: CGFloat = Theme.sidebarContentSideSpacing - Theme.sidebarItemInnerSpacing
  public static let sidebarNativeDefaultEdgeInsets: CGFloat = 16.0

  // MARK: - Message View

  public static let messageMaxWidth: CGFloat = 420
  public static let messageOuterVerticalPadding: CGFloat = 1.0 // gap between consequetive messages
  public static let messageSidePadding: CGFloat = 16.0
  public static let messageAvatarSize: CGFloat = 28
  // between avatar and content
  public static let messageHorizontalStackSpacing: CGFloat = 8.0
  public static let messageNameLabelHeight: CGFloat = 16
  public nonisolated(unsafe) static let messageTextFont: NSFont = .systemFont(
    ofSize: NSFont.systemFontSize
  )
  public static let messageTextFontSize: Double = NSFont.systemFontSize
  public static let messageTextFontSizeSingleEmoji = 64.0
  public static let messageTextFontSizeThreeEmojis = 42.0
  public static let messageTextFontSizeManyEmojis = 18.0
  public static let messageTextLineFragmentPadding: CGFloat = 0
  public static let messageTextContainerInset: NSSize = .zero
  public static let messageTextViewPadding: CGFloat = 0
  public static let messageContentViewSpacing: CGFloat = 8.0
  static var messageRowMaxWidth: CGFloat {
    Theme.messageMaxWidth + Theme.messageAvatarSize + Theme.messageSidePadding + Theme
      .messageHorizontalStackSpacing + Theme.messageRowSafeAreaInset
  }

  // - after bubble -
  public static let messageBubblePrimaryBgColor: NSColor = .init(name: "messageBubblePrimaryBgColor") { appearance in
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

  public static let messageBubbleSecondaryBgColor: NSColor =
    .init(name: "messageBubbleSecondaryBgColor") { appearance in
      appearance.name == .darkAqua ? NSColor.white
        .withAlphaComponent(0.1) : .init(
          calibratedRed: 236 / 255,
          green: 236 / 255,
          blue: 236 / 255,
          alpha: 1.0
        )
    }

  /// used for bubbles diff to edge
  public static let messageRowSafeAreaInset: CGFloat = 50.0
  public static let messageBubbleContentHorizontalInset: CGFloat = 11.0
  public static let messageSingleLineTextOnlyHeight: CGFloat = 28.0
  public static let messageBubbleCornerRadius: CGFloat = 14.0
  public static let messageTimeHeight: CGFloat = 13.0
  public static let messageTextOnlyVerticalInsets: CGFloat = 6.0
  public static let messageTextAndPhotoSpacing: CGFloat = 10.0
  public static let messageTextAndTimeSpacing: CGFloat = 0.0

  // MARK: - Chat View

  public static let chatToolbarIconSize: CGFloat = 30
  public static let chatViewMinWidth: CGFloat = 315 // going below this makes media calcs mess up
  public static let messageGroupSpacing: CGFloat = 8
  public static let messageListTopInset: CGFloat = 14
  public static let messageListBottomInset: CGFloat = 10
  public static let embeddedMessageHeight: CGFloat = 40.0
  public static let documentViewHeight: CGFloat = 36.0
  public static let documentViewWidth: CGFloat = 200.0
  public static let attachmentViewWidth: CGFloat = 260.0
  public static let externalTaskViewHeight: CGFloat = 46.0
  public static let loomPreviewHeight: CGFloat = 84.0
  public static let messageAttachmentsSpacing: CGFloat = 8.0
  public static let scrollButtonSize: CGFloat = 32.0

  public static let composeMinHeight: CGFloat = 44
  public static let composeAttachmentsVPadding: CGFloat = 6
  public static let composeAttachmentImageHeight: CGFloat = 80
  public static let composeButtonSize: CGFloat = 28
  public static let composeTextViewHorizontalPadding: CGFloat = 10.0
  public static let composeVerticalPadding: CGFloat = 2.0 // inner, higher makes 2 line compose increase height
  public static let composeOuterSpacing: CGFloat = 18 // horizontal
  public static let composeOutlineColor: NSColor = .init(name: "composeOutlineColor") { appearance in
    appearance.name == .darkAqua ? NSColor.white
      .withAlphaComponent(0.1) : NSColor.black
      .withAlphaComponent(0.09)
  }

  // MARK: - Devtools

  public static let devtoolsHeight: CGFloat = 30
}

extension NSColor {
  convenience init(_ name: String, light: NSColor, dark: NSColor) {
    self.init(name: name) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }
  }
}
