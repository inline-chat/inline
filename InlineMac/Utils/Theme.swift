import AppKit
import Foundation
import SwiftUI

struct Theme {
  // MARK: - Window
  static let windowMinimumSize: CGSize = .init(width: 320, height: 300)
  
  // MARK: - Main View & Split View
  static let collapseSidebarAtWindowSize: CGFloat = 500
  
  // MARK: - Sidebar
  /// 190 is minimum that fits both sidebar collapse button and plus button
  static let minimumSidebarWidth: CGFloat = 200
  static let idealSidebarWidth: CGFloat = 240
  static let sidebarIconSize: CGFloat = 24
  static let sidebarIconSpacing: CGFloat = 6
  static let sidebarItemRadius: CGFloat = 6
  static let sidebarItemPadding: CGFloat = 8
  static let sidebarItemHeight: CGFloat = 30
  static let sidebarTopItemFont: Font = .system(size: 14, weight: .semibold)
  static let sidebarTopItemHeight: CGFloat = 34
  
  
  
  // MARK: - Message View
  static let messageSidePadding: CGFloat = 16
  static let messageVerticalPadding: CGFloat = 4
  static let messageAvatarSize: CGFloat = 28
  static let messageHorizontalStackSpacing: CGFloat = 8
  static let messageVerticalStackSpacing: CGFloat = 0
  static let messageNameLabelHeight: CGFloat = 18
  static let messageTextFont: NSFont = .systemFont(ofSize: 14)
  static let messageSenderFont: NSFont = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
  static let messageTextLineFragmentPadding: CGFloat = 0
  static let messageTextContainerInset: NSSize = .zero
  static let messageTextViewPadding: CGFloat = 0
  
  // MARK: - Chat View
  static let messageListBottomInset: CGFloat = 10
}
