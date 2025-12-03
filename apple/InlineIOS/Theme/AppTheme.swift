import SwiftUI
import UIKit

struct AppTheme: Equatable, Identifiable {
  let id: String
  let name: String
  let colors: ThemeColors

  static func == (lhs: AppTheme, rhs: AppTheme) -> Bool {
    lhs.id == rhs.id
  }
}

extension AppTheme {
  static func find(byId id: String) -> AppTheme? {
    allThemes.first { $0.id == id }
  }
}
