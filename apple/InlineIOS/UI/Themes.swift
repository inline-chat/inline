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
}

struct Lavender: ThemeConfig {
  var primaryTextColor: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#EAEFFF")!
    } else {
      UIColor(hex: "#000000")!
    }
  })

  var secondaryTextColor: UIColor? = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#696A85")!
    } else {
      UIColor(hex: "#BDC2D1")!
    }
  })

  var id: String = "lavender"

  var name: String = "Lavender"

  var backgroundColor: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#11111B")!
    } else {
      UIColor(hex: "#FFFFFF")!
    }
  })

  var bubbleBackground: UIColor = .init(hex: "#7A8AEF")!
  var incomingBubbleBackground: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#313244")!
    } else {
      UIColor(hex: "#EFF1F8")!
    }
  })

  var accent: UIColor = .init(hex: "#8293FF")!
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
}

struct Orchid: ThemeConfig {
  var primaryTextColor: UIColor?

  var secondaryTextColor: UIColor?

  var id: String = "Orchid"

  var name: String = "Orchid"

  var backgroundColor: UIColor = .systemBackground

  var bubbleBackground: UIColor = .init(hex: "#CF7DFF")!
  var incomingBubbleBackground: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#8b77dc")!
    } else {
      UIColor(hex: "#a28cf2")!
    }
  })

  var accent: UIColor = .init(hex: "#a28cf2")!
}
