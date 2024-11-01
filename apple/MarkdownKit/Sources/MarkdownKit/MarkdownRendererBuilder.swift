import Foundation
import UIKit

public final class MarkdownRendererBuilder {
  private var theme: MarkdownTheme = .default

  @discardableResult
  public func with(theme: MarkdownTheme) -> Self {
    self.theme = theme
    return self
  }

  public func build() -> MarkdownRenderer {
    return MarkdownRenderer(theme: theme)
  }
}
