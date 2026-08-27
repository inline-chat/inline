struct ComposeMenuCapabilities: OptionSet {
  let rawValue: Int

  static let mediaPicker = Self(rawValue: 1 << 0)
  static let camera = Self(rawValue: 1 << 1)
  static let files = Self(rawValue: 1 << 2)
  static let sendSilently = Self(rawValue: 1 << 3)
  static let commands = Self(rawValue: 1 << 4)

  static let chatDefault: Self = [.mediaPicker, .camera, .files, .sendSilently, .commands]
  static let newThread: Self = [.mediaPicker, .files]
}

/// Feature availability is independent from Glass Compose topology. This lets
/// a host select an integrated layout without implicitly enabling chat-only
/// controls, or hide one control without changing the editor hierarchy.
struct ComposeCapabilities {
  let menu: ComposeMenuCapabilities
  let showsEmojiButton: Bool
  let supportsVoiceMessages: Bool

  static let chatDefault = Self(
    menu: .chatDefault,
    showsEmojiButton: true,
    supportsVoiceMessages: true
  )

  static let allChatsNewThread = Self(
    menu: .newThread,
    showsEmojiButton: false,
    supportsVoiceMessages: false
  )
}
