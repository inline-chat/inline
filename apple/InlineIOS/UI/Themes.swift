import SwiftUI

struct Default: ThemeConfig {
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
  var id: String = "lavender"

  var name: String = "Lavender"

  var backgroundColor: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#11111B")!
    } else {
      UIColor(hex: "#FFFFFF")!
    }
  })

  var bubbleBackground: UIColor = .init(hex: "#8293FF")!
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
  var id: String = "Orchid"

  var name: String = "Orchid"

  var backgroundColor: UIColor = .systemBackground

  var bubbleBackground: UIColor = .init(hex: "#CF7DFF")!
  var incomingBubbleBackground: UIColor = .init(dynamicProvider: { trait in
    if trait.userInterfaceStyle == .dark {
      UIColor(hex: "#27262B")!
    } else {
      UIColor(hex: "#F2F2F2")!
    }
  })

  var accent: UIColor = .init(hex: "#CF7DFF")!
}
