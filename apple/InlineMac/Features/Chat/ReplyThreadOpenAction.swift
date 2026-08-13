import AppKit

enum ReplyThreadOpenAction: Equatable {
  case sidePane
  case current
  case newTab

  init(opensInSidePane: Bool) {
    self = opensInSidePane ? .sidePane : .current
  }

  init(modifierFlags: NSEvent.ModifierFlags, opensInSidePane: Bool) {
    if modifierFlags.contains(.option) {
      self = .sidePane
    } else if modifierFlags.contains(.command) {
      self = .newTab
    } else {
      self.init(opensInSidePane: opensInSidePane)
    }
  }

  var usesCurrentWindowPresentation: Bool {
    self == .sidePane || self == .current
  }
}
