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
}
