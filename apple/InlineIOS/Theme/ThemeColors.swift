import SwiftUI
import UIKit

struct ThemeColors: Equatable {
  // MARK: - Message Bubbles

  let bubbleOutgoing: UIColor
  let bubbleIncoming: UIColor
  let bubbleFailed: UIColor

  // MARK: - Accent

  let accent: UIColor

  // MARK: - Text

  let textPrimary: UIColor
  let textSecondary: UIColor
  let textTertiary: UIColor

  // MARK: - Surfaces

  let background: UIColor
  let surface: UIColor
  let surfaceSecondary: UIColor
  let card: UIColor

  // MARK: - Reactions

  let reactionOutgoingPrimary: UIColor
  let reactionOutgoingSecondary: UIColor
  let reactionIncomingPrimary: UIColor
  let reactionIncomingSecondary: UIColor

  // MARK: - UI Elements

  let documentIconBackground: UIColor
  let separator: UIColor
  let border: UIColor
  let overlay: UIColor

  // MARK: - Buttons

  let buttonPrimary: UIColor
  let buttonSecondary: UIColor

  // MARK: - Navigation

  let navigationBar: UIColor
  let toolbar: UIColor
  let searchBar: UIColor

  // MARK: - Semantic

  let destructive: UIColor

  static func == (lhs: ThemeColors, rhs: ThemeColors) -> Bool {
    true
  }
}

// MARK: - SwiftUI Color Accessors

extension ThemeColors {
  var bubbleOutgoingColor: Color { Color(bubbleOutgoing) }
  var bubbleIncomingColor: Color { Color(bubbleIncoming) }
  var bubbleFailedColor: Color { Color(bubbleFailed) }

  var accentColor: Color { Color(accent) }

  var textPrimaryColor: Color { Color(textPrimary) }
  var textSecondaryColor: Color { Color(textSecondary) }
  var textTertiaryColor: Color { Color(textTertiary) }

  var backgroundColor: Color { Color(background) }
  var surfaceColor: Color { Color(surface) }
  var surfaceSecondaryColor: Color { Color(surfaceSecondary) }
  var cardColor: Color { Color(card) }

  var separatorColor: Color { Color(separator) }
  var borderColor: Color { Color(border) }
  var overlayColor: Color { Color(overlay) }

  var buttonPrimaryColor: Color { Color(buttonPrimary) }
  var buttonSecondaryColor: Color { Color(buttonSecondary) }

  var destructiveColor: Color { Color(destructive) }
}

// MARK: - Defaults

extension ThemeColors {
  static let systemDefaults = ThemeColors(
    bubbleOutgoing: UIColor(hex: "#52A5FF")!,
    bubbleIncoming: .dynamic(light: "#F2F2F2", dark: "#27262B"),
    bubbleFailed: .systemRed,
    accent: UIColor(hex: "#52A5FF")!,
    textPrimary: .label,
    textSecondary: .secondaryLabel,
    textTertiary: .tertiaryLabel,
    background: .systemBackground,
    surface: .secondarySystemBackground,
    surfaceSecondary: .tertiarySystemBackground,
    card: .secondarySystemBackground,
    reactionOutgoingPrimary: .white,
    reactionOutgoingSecondary: .white.withAlphaComponent(0.08),
    reactionIncomingPrimary: UIColor(hex: "#52A5FF")!,
    reactionIncomingSecondary: .dynamic(light: "#e2e5e5", dark: "#3c3b43"),
    documentIconBackground: .dynamic(light: "#e2e5e5", dark: "#3c3b43"),
    separator: .separator,
    border: .separator,
    overlay: .systemGray,
    buttonPrimary: UIColor(hex: "#52A5FF")!,
    buttonSecondary: .systemGray2,
    navigationBar: .systemBackground,
    toolbar: .systemBackground,
    searchBar: .systemGray6,
    destructive: .systemRed
  )
}
