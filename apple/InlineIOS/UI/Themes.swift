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
}
