import MacTheme

typealias Theme = MacTheme.Theme

/// Implemented by layer-backed AppKit views that retain resolved theme colors.
protocol AppThemeRefreshable: AnyObject {
  func refreshAppTheme()
}
