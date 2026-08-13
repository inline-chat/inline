import Foundation

enum SidebarSortMode: String, CaseIterable, Identifiable {
  case openedOrder
  case recentActivity

  var id: String { rawValue }

  var title: String {
    switch self {
    case .openedOrder:
      "Opened Time"
    case .recentActivity:
      "Recent Activity"
    }
  }

  var detail: String {
    switch self {
    case .openedOrder:
      "Manual order"
    case .recentActivity:
      "Newest messages first"
    }
  }
}
