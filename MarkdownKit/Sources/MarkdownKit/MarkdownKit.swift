import Foundation

public final class MarkdownKit {
    public static let version = "1.0.0"
    
    public static func editor() -> MarkdownEditorBuilder {
        return MarkdownEditorBuilder()
    }
    
    public static func renderer() -> MarkdownRendererBuilder {
        return MarkdownRendererBuilder()
    }
}