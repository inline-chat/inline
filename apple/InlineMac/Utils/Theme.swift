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
  static let messageVerticalPadding: CGFloat = 4
  static let messageAvatarSize: CGFloat = 28
//  Space between avatar and content
  static let messageHorizontalStackSpacing: CGFloat = 8
  static let messageVerticalStackSpacing: CGFloat = 0
  static let messageNameLabelHeight: CGFloat = 18
  static let messageTextFont: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
  static let messageSenderFont: NSFont = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
  static let messageTextLineFragmentPadding: CGFloat = 0
  static let messageTextContainerInset: NSSize = .zero
  static let messageTextViewPadding: CGFloat = 0
  
  // MARK: - Chat View

  static let messageListTopInset: CGFloat = 14
  static let messageListBottomInset: CGFloat = 10
}
