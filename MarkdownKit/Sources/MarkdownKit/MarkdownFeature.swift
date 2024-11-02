import Foundation

public enum MarkdownFeature: CaseIterable {
  case bold /// **text**
  case italic /// *text*
  case codeBlock /// ```code```
  case bulletList /// - item
  case numberList /// 1. item
  case link /// [text](url)
  case autoFormatting /// Enable automatic markdown formatting
}
