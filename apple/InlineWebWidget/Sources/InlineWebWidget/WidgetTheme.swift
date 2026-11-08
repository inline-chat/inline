import Foundation

/// CSS variables handed to a widget. Primary names follow shadcn (as Codex and
/// T3 Code do); Claude and MCP Apps names are aliases so widgets authored for
/// those hosts render with Inline colors.
public struct WidgetTheme: Equatable, Sendable {
  public enum Appearance: String, Sendable { case light, dark }

  public var appearance: Appearance
  public var variables: [String: String]

  public init(appearance: Appearance, variables: [String: String]) {
    self.appearance = appearance
    self.variables = variables.merging(Self.aliases) { current, _ in current }
  }

  /// Snapshot cache key. Accent or contrast changes clear the cache instead.
  public var cacheKey: String { appearance.rawValue }

  public var rootRule: String {
    var css = ":root{color-scheme:\(appearance.rawValue);"
    for (name, value) in variables.sorted(by: { $0.key < $1.key }) {
      css += "\(name):\(Self.sanitize(value));"
    }
    return css + "}"
  }

  static func sanitize(_ value: String) -> String {
    String(value.filter { !";{}<>".contains($0) })
  }

  static let aliases: [String: String] = [
    // Claude visualize names.
    "--text-primary": "var(--foreground)",
    "--text-secondary": "var(--muted-foreground)",
    "--text-muted": "var(--muted-foreground)",
    "--surface-0": "var(--background)",
    "--surface-1": "var(--muted)",
    "--surface-2": "var(--card)",
    "--border-strong": "var(--border-strong-color)",
    "--bg-accent": "var(--accent)",
    "--text-accent": "var(--accent-foreground)",
    "--bg-danger": "var(--destructive-surface)",
    "--text-danger": "var(--destructive)",
    "--bg-success": "var(--success-surface)",
    "--text-success": "var(--success)",
    "--bg-warning": "var(--warning-surface)",
    "--text-warning": "var(--warning)",
    // MCP Apps standard names.
    "--color-background-primary": "var(--background)",
    "--color-background-secondary": "var(--muted)",
    "--color-text-primary": "var(--foreground)",
    "--color-text-secondary": "var(--muted-foreground)",
    "--color-border-primary": "var(--border)",
    "--color-ring-primary": "var(--ring)",
    "--border-radius-md": "var(--radius)",
    // Codex visualize names.
    "--viz-series-1": "var(--chart-1)",
    "--viz-series-2": "var(--chart-2)",
    "--viz-series-3": "var(--chart-3)",
    "--viz-series-4": "var(--chart-4)",
    "--viz-series-5": "var(--chart-5)",
    "--viz-series-6": "var(--chart-6)",
    "--font-size-base": "14px",
  ]
}

#if canImport(AppKit)
import AppKit

public extension WidgetTheme {
  /// Resolves system colors in the given appearance.
  @MainActor
  static func current(for appearance: NSAppearance) -> WidgetTheme {
    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    var variables: [String: String] = [:]
    appearance.performAsCurrentDrawingAppearance {
      func css(_ color: NSColor, alpha: CGFloat? = nil) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "transparent" }
        let a = alpha ?? c.alphaComponent
        return String(format: "rgba(%d,%d,%d,%.3f)", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255), a)
      }
      let accent = NSColor.controlAccentColor
      variables = [
        "--background": css(.windowBackgroundColor),
        "--foreground": css(.labelColor),
        "--muted": css(.labelColor, alpha: isDark ? 0.08 : 0.05),
        "--muted-foreground": css(.secondaryLabelColor),
        "--card": css(isDark ? .white : .white, alpha: isDark ? 0.05 : 1),
        "--card-foreground": css(.labelColor),
        "--border": css(.separatorColor),
        "--border-strong-color": css(.labelColor, alpha: isDark ? 0.22 : 0.18),
        "--input": css(.separatorColor),
        "--ring": css(accent),
        "--primary": css(accent),
        "--primary-foreground": css(.white),
        "--accent": css(accent, alpha: isDark ? 0.22 : 0.12),
        "--accent-foreground": css(accent),
        "--destructive": css(.systemRed),
        "--destructive-surface": css(.systemRed, alpha: 0.14),
        "--warning": css(.systemOrange),
        "--warning-surface": css(.systemOrange, alpha: 0.14),
        "--success": css(.systemGreen),
        "--success-surface": css(.systemGreen, alpha: 0.14),
        "--info": css(.systemBlue),
        "--chart-1": css(.systemBlue),
        "--chart-2": css(.systemOrange),
        "--chart-3": css(.systemTeal),
        "--chart-4": css(.systemPurple),
        "--chart-5": css(.systemPink),
        "--chart-6": css(.systemGreen),
        "--radius": "8px",
        "--font-sans": "-apple-system, BlinkMacSystemFont, system-ui, sans-serif",
        "--font-mono": "ui-monospace, \"SF Mono\", Menlo, monospace",
      ]
    }
    return WidgetTheme(appearance: isDark ? .dark : .light, variables: variables)
  }
}
#endif
