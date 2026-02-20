import CoreGraphics

enum TrafficLightInsetPreset {
  case sidebarVisible
  case sidebarHidden
  case sidebarVisibleWithTabStrip
  case sidebarHiddenWithTabStrip

  private static let sidebarVisibleInset = CGPoint(x: 20, y: 20)
  private static let sidebarHiddenInset = CGPoint(x: 24, y: 24)
  private static let sidebarVisibleWithTabStripInset = CGPoint(x: 18, y: 16)
  private static let sidebarHiddenWithTabStripInset = CGPoint(x: 18, y: 16)

  var inset: CGPoint {
    switch self {
    case .sidebarVisible:
      return Self.sidebarVisibleInset

    case .sidebarHidden:
      return Self.sidebarHiddenInset

    case .sidebarVisibleWithTabStrip:
      return Self.sidebarVisibleWithTabStripInset

    case .sidebarHiddenWithTabStrip:
      return Self.sidebarHiddenWithTabStripInset
    }
  }
}
