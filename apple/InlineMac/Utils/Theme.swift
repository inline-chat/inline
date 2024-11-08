import AppKit
import SwiftUI
import Foundation

struct Theme {
    // MARK: - Sidebar
    /// 190 is minimum that fits both sidebar collapse button and plus button
    static let minimumSidebarWidth: CGFloat = 200
    static let idealSidebarWidth: CGFloat = 240
    static let sidebarIconSize: CGFloat = 24
    static let sidebarIconSpacing: CGFloat = 6
    static let sidebarItemRadius: CGFloat = 6
    static let sidebarItemPadding: CGFloat = 4
    static let sidebarItemHeight: CGFloat = 30
    static let sidebarTopItemFont: Font = .system(size: 14, weight: .semibold)
    static let sidebarTopItemHeight: CGFloat = 34
}
