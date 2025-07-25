import SwiftUI

struct Default: ThemeConfig {
  var primaryTextColor: UIColor?

  var secondaryTextColor: UIColor?

  var id: String = "Default"

  var name: String = "Default"

  var backgroundColor: UIColor = .systemBackground

  var bubbleBackground: UIColor = .init(hex: "#52A5FF")!
  var incomingBubbleBackground: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#27262B")!
    } else {
      UIColor(hex: "#F2F2F2")!
    }
  })

  var accent: UIColor = .init(hex: "#52A5FF")!

  var reactionOutgoingPrimary: UIColor? = .white
  var reactionOutgoingSecoundry: UIColor? = .white.withAlphaComponent(0.08)

  var reactionIncomingPrimary: UIColor? { accent }
  var reactionIncomingSecoundry: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#3c3b43")!
    } else {
      UIColor(hex: "#e2e5e5")!
    }
  })

  var documentIconBackground: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#3c3b43")!
    } else {
      UIColor(hex: "#e2e5e5")!
    }
  })

  var listRowBackground: UIColor? { nil }
  var listSeparatorColor: UIColor? { nil }
  var navigationBarBackground: UIColor? { nil }
  var toolbarBackground: UIColor? { nil }
  var surfaceBackground: UIColor? { nil }
  var surfaceSecondary: UIColor? { nil }
  var textPrimary: UIColor? { nil }
  var textSecondary: UIColor? { nil }
  var textTertiary: UIColor? { nil }
  var borderColor: UIColor? { nil }
  var overlayBackground: UIColor? { nil }
  var cardBackground: UIColor? { nil }
  var searchBarBackground: UIColor? { nil }
  var buttonBackground: UIColor? { nil }
  var buttonSecondaryBackground: UIColor? { nil }
  var sheetTintColor: UIColor? { nil }
  var logoutRed: UIColor = .red
}

struct CatppuccinMocha: ThemeConfig {
  var primaryTextColor: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#FFFFFF")!
    } else {
      UIColor(hex: "#4C4F69")!
    }
  })

  var secondaryTextColor: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#CDD6F4")!
    } else {
      UIColor(hex: "#4C4F69")!
    }
  })

  var id: String = "CatppuccinMocha"

  var name: String = "Catppuccin Mocha"

  var backgroundColor: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#11111B")!
    } else {
      UIColor(hex: "#FFFFFF")!
    }
  })

  var bubbleBackground: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#919EF4")!
    } else {
      UIColor(hex: "#7287FD")!
    }
  })
  var incomingBubbleBackground: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#313244")!
    } else {
      UIColor(hex: "#EFF1F5")!
    }
  })

  var accent: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#919EF4")!
    } else {
      UIColor(hex: "#7287FD")!
    }
  })

  var reactionOutgoingPrimary: UIColor? = .white
  var reactionOutgoingSecoundry: UIColor? = .white.withAlphaComponent(0.08)

  var reactionIncomingPrimary: UIColor? { accent }
  var reactionIncomingSecoundry: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#41435d")!
    } else {
      UIColor(hex: "#dddfe6")!
    }
  })

  var documentIconBackground: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#41435d")!
    } else {
      UIColor(hex: "#dddfe6")!
    }
  })

  // Enhanced Catppuccin Mocha theming - synchronized backgrounds
  var listRowBackground: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#11111B")!
    } else {
      UIColor(hex: "#FFFFFF")!
    }
  })

  var listSeparatorColor: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#6C7086")!
    } else {
      UIColor(hex: "#9CA0B0")!
    }
  })

  var navigationBarBackground: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#11111B")!
    } else {
      UIColor(hex: "#FFFFFF")!
    }
  })

  var toolbarBackground: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#11111B")! // Match main background
    } else {
      UIColor(hex: "#FFFFFF")! // Match main background
    }
  })

  var surfaceBackground: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#313244")!
    } else {
      UIColor(hex: "#CCD0DA")!
    }
  })

  var surfaceSecondary: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#45475A")!
    } else {
      UIColor(hex: "#BCC0CC")!
    }
  })

  var textPrimary: UIColor? { nil }
  var textSecondary: UIColor? { nil }
  var textTertiary: UIColor? { nil }

  var borderColor: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#585B70")!
    } else {
      UIColor(hex: "#ACB0BE")!
    }
  })

  var overlayBackground: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#7F849C")!
    } else {
      UIColor(hex: "#8C8FA1")!
    }
  })

  var cardBackground: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#181825")!
    } else {
      UIColor(hex: "#E6E9EF")!
    }
  })

  var searchBarBackground: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#313244")!
    } else {
      UIColor(hex: "#CCD0DA")!
    }
  })

  var buttonBackground: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#CBA6F7")!
    } else {
      UIColor(hex: "#8839EF")!
    }
  })

  var buttonSecondaryBackground: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#45475A")!
    } else {
      UIColor(hex: "#BCC0CC")!
    }
  })

  var sheetTintColor: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#919EF4")!
    } else {
      UIColor(hex: "#7287FD")!
    }
  })

  var logoutRed: UIColor = .red
}

struct PeonyPink: ThemeConfig {
  var primaryTextColor: UIColor?

  var secondaryTextColor: UIColor?

  var id: String = "PeonyPink"

  var name: String = "Peony Pink"

  var backgroundColor: UIColor = .systemBackground

  var bubbleBackground: UIColor = .init(hex: "#FF82B8")!
  var incomingBubbleBackground: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#27262B")!
    } else {
      UIColor(hex: "#F2F2F2")!
    }
  })

  var accent: UIColor = .init(hex: "#FF82B8")!
  var reactionOutgoingPrimary: UIColor? = .white
  var reactionOutgoingSecoundry: UIColor? = .white.withAlphaComponent(0.08)

  var reactionIncomingPrimary: UIColor? { accent }
  var reactionIncomingSecoundry: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#3c3b43")!
    } else {
      UIColor(hex: "#e2e5e5")!
    }
  })

  var documentIconBackground: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#3c3b43")!
    } else {
      UIColor(hex: "#e2e5e5")!
    }
  })

  var listRowBackground: UIColor? { nil }
  var listSeparatorColor: UIColor? { nil }
  var navigationBarBackground: UIColor? { nil }
  var toolbarBackground: UIColor? { nil }
  var surfaceBackground: UIColor? { nil }
  var surfaceSecondary: UIColor? { nil }
  var textPrimary: UIColor? { nil }
  var textSecondary: UIColor? { nil }
  var textTertiary: UIColor? { nil }
  var borderColor: UIColor? { nil }
  var overlayBackground: UIColor? { nil }
  var cardBackground: UIColor? { nil }
  var searchBarBackground: UIColor? { nil }
  var buttonBackground: UIColor? { nil }
  var buttonSecondaryBackground: UIColor? { nil }
  var sheetTintColor: UIColor? { nil }
  var logoutRed: UIColor = .red
}

struct Orchid: ThemeConfig {
  var primaryTextColor: UIColor?

  var secondaryTextColor: UIColor?

  var id: String = "Orchid"

  var name: String = "Orchid"

  var backgroundColor: UIColor = .systemBackground

  var bubbleBackground: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#8b77dc")!
    } else {
      UIColor(hex: "#a28cf2")!
    }
  })
  var incomingBubbleBackground: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#27262B")!
    } else {
      UIColor(hex: "#F2F2F2")!
    }
  })

  var accent: UIColor = .init(hex: "#a28cf2")!

  var reactionOutgoingPrimary: UIColor? = .white
  var reactionOutgoingSecoundry: UIColor? = .white.withAlphaComponent(0.08)

  var reactionIncomingPrimary: UIColor? { accent }
  var reactionIncomingSecoundry: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#3c3b43")!
    } else {
      UIColor(hex: "#e2e5e5")!
    }
  })

  var documentIconBackground: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#3c3b43")!
    } else {
      UIColor(hex: "#e2e5e5")!
    }
  })

  var listRowBackground: UIColor? { nil }
  var listSeparatorColor: UIColor? { nil }
  var navigationBarBackground: UIColor? { nil }
  var toolbarBackground: UIColor? { nil }
  var surfaceBackground: UIColor? { nil }
  var surfaceSecondary: UIColor? { nil }
  var textPrimary: UIColor? { nil }
  var textSecondary: UIColor? { nil }
  var textTertiary: UIColor? { nil }
  var borderColor: UIColor? { nil }
  var overlayBackground: UIColor? { nil }
  var cardBackground: UIColor? { nil }
  var searchBarBackground: UIColor? { nil }
  var buttonBackground: UIColor? { nil }
  var buttonSecondaryBackground: UIColor? { nil }
  var sheetTintColor: UIColor? { nil }
  var logoutRed: UIColor = .red
}
