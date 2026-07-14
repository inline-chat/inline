import AppKit

enum ReplyThreadOpenAction: Equatable {
  case sidePane
  case current
  case sidebarBackground
  case newTab

  init(modifierFlags: NSEvent.ModifierFlags, opensInSidePane: Bool) {
    if modifierFlags.contains(.option) {
      self = .sidebarBackground
    } else if modifierFlags.contains(.command) {
      self = .newTab
    } else {
      self = opensInSidePane ? .sidePane : .current
    }
  }

  var usesCurrentWindowPresentation: Bool {
    self == .sidePane || self == .current
  }
}
