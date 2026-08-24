import AppKit

enum RichBlockCodeMetrics {
  static let languageHeaderHeight: CGFloat = 21
  static let headerControlTopInset: CGFloat = 5
  static let headerControlHeight: CGFloat = 14
  static let horizontalInset: CGFloat = 8
  static let languageBodyTopInset: CGFloat = 3
  static let overlayBodyTopInset: CGFloat = 8
  static let bodyBottomInset: CGFloat = 9
  static let gutterTextTrailingInset: CGFloat = 4
  static let gutterContentGap: CGFloat = 15
  static let bodyFontSize = NSFont.systemFontSize * 0.92
  static let bodyFont = NSFont.monospacedSystemFont(ofSize: bodyFontSize, weight: .regular)
  static let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: bodyFontSize, weight: .regular)

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

  static func bodyWidth(containerWidth: CGFloat, gutterWidth: CGFloat) -> CGFloat {
    let contentGap = gutterWidth > 0 ? gutterContentGap : 0
    return max(1, containerWidth - horizontalInset * 2 - gutterWidth - contentGap)
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
