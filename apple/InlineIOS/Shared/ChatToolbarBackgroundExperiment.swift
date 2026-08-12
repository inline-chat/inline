/// Keeps Inline's existing blur unless the iOS 27 custom-toolbar experiment is explicitly enabled.
enum ChatToolbarBackgroundExperiment {
  enum Implementation {
    case variableBlur
    case customToolbarBackground
  }

  static let key = "enableCustomChatToolbarBackground"
  static let defaultValue = false

  static func implementation(customBackgroundEnabled: Bool) -> Implementation {
    if #available(iOS 27.0, *), customBackgroundEnabled {
      return .customToolbarBackground
    }
    return .variableBlur
  }
}
