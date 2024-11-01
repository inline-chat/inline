import Foundation
import UIKit

public struct MarkdownTheme: Sendable {
    public let backgroundColor: UIColor
    public let textColor: UIColor
    public let codeBackground: UIColor
    public let codeForeground: UIColor
    public let linkColor: UIColor

    public let normalFont: UIFont
    public let boldFont: UIFont
    public let italicFont: UIFont
    public let codeFont: UIFont

    public static let `default` = MarkdownTheme(
        backgroundColor: .systemBackground,
        textColor: .label,
        codeBackground: .secondarySystemBackground,
        codeForeground: .label,
        linkColor: .systemBlue,
        normalFont: .systemFont(ofSize: 14),
        boldFont: .boldSystemFont(ofSize: 14),
        italicFont: .italicSystemFont(ofSize: 14),
        codeFont: .monospacedSystemFont(ofSize: 14, weight: .regular)
    )
}
