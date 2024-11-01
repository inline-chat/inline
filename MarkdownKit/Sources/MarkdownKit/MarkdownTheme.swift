import Foundation
import UIKit

public struct MarkdownTheme: Sendable {
  // MARK: Colors
  public let backgroundColor: UIColor // Text view background
  public let textColor: UIColor // Normal text color
  public let codeBackground: UIColor // Code block background
  public let codeForeground: UIColor // Code text color
  public let linkColor: UIColor // Link text color

  // MARK: Fonts
  public let normalFont: UIFont // Regular text
  public let boldFont: UIFont // Bold text
  public let italicFont: UIFont // Italic text
  public let codeFont: UIFont // Monospace code font

  // MARK: Default theme using system colors
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
