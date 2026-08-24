import MacTheme

typealias Theme = MacTheme.Theme
typealias ChatTypography = MacTheme.ChatTypography

/// Implemented by layer-backed AppKit views that retain resolved theme colors.
protocol AppThemeRefreshable: AnyObject {
  func refreshAppTheme()
}
