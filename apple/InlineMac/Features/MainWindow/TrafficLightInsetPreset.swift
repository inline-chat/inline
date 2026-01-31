import CoreGraphics

enum TrafficLightInsetPreset {
  case sidebarVisible
  case sidebarHidden

  private static let sidebarVisibleInset = CGPoint(x: 20, y: 20)
  private static let sidebarHiddenInset = CGPoint(x: 24, y: 24)

  var inset: CGPoint {
    switch self {
    case .sidebarVisible:
      return Self.sidebarVisibleInset

    case .sidebarHidden:
      return Self.sidebarHiddenInset
    }
  }
}
