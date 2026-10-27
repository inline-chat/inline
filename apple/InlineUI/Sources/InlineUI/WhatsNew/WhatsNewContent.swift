extension WhatsNewAnnouncement {
  /// Shown once after updating to a build that carries it. Set to nil for releases
  /// that don't need one, and give each new announcement a new id.
  public static let current: WhatsNewAnnouncement? = WhatsNewAnnouncement(
    id: "2026-10-voice-chat-info",
    items: [
      WhatsNewItem(
        systemImage: "headphones",
        title: "Voice Messages Keep Playing",
        detail: "Switch chats or lock your phone. A playback bar lets you pause, change speed, or jump back.",
        platforms: .iOS
      ),
      WhatsNewItem(
        systemImage: "folder",
        title: "Send Folders",
        detail: "Drop or attach a folder and Inline zips it for you.",
        platforms: .macOS
      ),
      WhatsNewItem(
        systemImage: "info.circle",
        title: "Rebuilt Chat Info",
        detail: "Files, media, links, and voice messages load reliably, even older ones."
      ),
      WhatsNewItem(
        systemImage: "textformat.size",
        title: "Your Text Size",
        detail: "Messages now follow your system text size.",
        platforms: .iOS
      ),
      WhatsNewItem(
        systemImage: "arrow.left.and.right",
        title: "Full-Width Chats",
        detail: "Turn off Centered Chats in Appearance settings to use the whole window.",
        platforms: .macOS
      ),
      WhatsNewItem(
        systemImage: "puzzlepiece.extension",
        title: "Inline in ChatGPT",
        detail: "Inline is now in the ChatGPT plugin store."
      ),
    ]
  )
}
