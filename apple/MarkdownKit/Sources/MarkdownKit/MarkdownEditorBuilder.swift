import Foundation
import UIKit

public final class MarkdownEditorBuilder {
    private var theme: MarkdownTheme = .default
    private var features: Set<MarkdownFeature> = Set(MarkdownFeature.allCases)

    @discardableResult
    public func with(theme: MarkdownTheme) -> Self {
        self.theme = theme
        return self
    }

    @discardableResult
    public func with(features: Set<MarkdownFeature>) -> Self {
        self.features = features
        return self
    }

    @MainActor public func build() -> MarkdownTextView {
        return MarkdownTextView(theme: theme, features: features)
    }
}
