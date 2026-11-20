import AppKit

enum RichBlockCodeMetrics {
  static let languageHeaderHeight: CGFloat = 24
  static let headerControlHeight: CGFloat = 14
  static var headerControlTopInset: CGFloat { floor((languageHeaderHeight - headerControlHeight) / 2) }
  static let labelFontSize: CGFloat = 11
  static let copyIconSize: CGFloat = 11
  /// Header and gutter chrome as alphas of the text color: the label reads first,
  /// line numbers recede.
  static let labelAlpha: CGFloat = 0.35
  static let copyIconAlpha: CGFloat = 0.5
  static let lineNumberAlpha: CGFloat = 0.28
  static let dividerAlpha: CGFloat = 0.08
  static let gutterTextTrailingInset: CGFloat = 4
  static let copyButtonSide: CGFloat = 16

  private static var basePointSize: CGFloat { ChatTypography.current.pointSize }
  /// One padding on every side, and between line numbers and code.
  static var horizontalInset: CGFloat { ChatTypography.space(.codePadding, at: basePointSize) }
  static var languageBodyTopInset: CGFloat { ChatTypography.space(.codeHeaderToBody, at: basePointSize) }
  static var overlayBodyTopInset: CGFloat { horizontalInset }
  static var bodyBottomInset: CGFloat { horizontalInset }
  static var gutterContentGap: CGFloat { horizontalInset }
  /// Code reads slightly smaller than the message text and follows its size and code font.
  static var bodyFontSize: CGFloat { ChatTypography.codeBlockPointSize(at: basePointSize) }
  static var bodyFont: NSFont { ChatTypography.current.codeFont(sized: bodyFontSize) }
  static var gutterFont: NSFont { NSFont.monospacedDigitSystemFont(ofSize: bodyFontSize, weight: .regular) }

  static func gutterWidth(lineCount: Int) -> CGFloat {
    let label = "\(max(1, lineCount))" as NSString
    let labelWidth = label.size(withAttributes: [.font: gutterFont]).width
    return ceil(labelWidth + gutterTextTrailingInset)
  }

  static func displayLanguage(_ language: String) -> String {
    let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
    return switch trimmed.lowercased() {
    case "bash", "sh", "shell", "zsh": "Shell"
    case "c": "C"
    case "c#", "csharp", "cs": "C#"
    case "c++", "cpp": "C++"
    case "css": "CSS"
    case "go", "golang": "Go"
    case "html": "HTML"
    case "javascript", "js": "JavaScript"
    case "json", "jsonc": "JSON"
    case "jsx": "JSX"
    case "kotlin": "Kotlin"
    case "objective-c", "objc": "Objective-C"
    case "python", "py", "python3": "Python"
    case "ruby", "rb": "Ruby"
    case "rust", "rs": "Rust"
    case "sql", "postgres", "postgresql": "SQL"
    case "swift": "Swift"
    case "tsx": "TSX"
    case "typescript", "ts": "TypeScript"
    case "xml": "XML"
    case "yaml", "yml": "YAML"
    default:
      trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
  }

  /// Without a language header the copy button overlays the body's top trailing
  /// corner, so the body keeps clear of it.
  static func bodyWidth(containerWidth: CGFloat, gutterWidth: CGFloat, hasLanguage: Bool) -> CGFloat {
    let contentGap = gutterWidth > 0 ? gutterContentGap : 0
    let copyRoom = hasLanguage ? 0 : copyButtonSide
    return max(1, containerWidth - horizontalInset * 2 - gutterWidth - contentGap - copyRoom)
  }

  static func headerHeight(hasLanguage: Bool) -> CGFloat {
    hasLanguage ? languageHeaderHeight : 0
  }

  static func bodyTopInset(hasLanguage: Bool) -> CGFloat {
    hasLanguage ? languageBodyTopInset : overlayBodyTopInset
  }

  static func totalHeight(bodyHeight: CGFloat, hasLanguage: Bool) -> CGFloat {
    headerHeight(hasLanguage: hasLanguage)
      + bodyTopInset(hasLanguage: hasLanguage)
      + bodyHeight
      + bodyBottomInset
  }
}
