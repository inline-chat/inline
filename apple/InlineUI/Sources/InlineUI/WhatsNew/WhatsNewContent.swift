extension WhatsNewAnnouncement {
  /// Shown once after updating to a build that carries it. Set to nil for releases
  /// that don't need one, and give each new announcement a new id.
  public static let current: WhatsNewAnnouncement? = WhatsNewAnnouncement(
    id: "2026-11-13-highlights",
    items: [
      WhatsNewItem(
        systemImage: "magnifyingglass",
        title: "Search Inside a Chat",
        detail: "Press Command-F to find messages in the chat you're in and jump straight to them.",
        platforms: .macOS
      ),
      WhatsNewItem(
        systemImage: "text.quote",
        title: "Quote Replies",
        detail: "Select part of a message and choose Quote to reply to just those words."
      ),
      WhatsNewItem(
        systemImage: "at",
        title: "Unread Mentions and Reactions",
        detail: "Badges and jump buttons take you to them, and chats open at your first unread message."
      ),
      WhatsNewItem(
        systemImage: "checkmark.circle",
        title: "Select Several Messages",
        detail: "Choose Select from the message menu, then forward, delete, or copy them together.",
        platforms: .macOS
      ),
      WhatsNewItem(
        systemImage: "moon",
        title: "Focus Status",
        detail: "When a Focus is on, people you choose see that your notifications are silenced."
      ),
      WhatsNewItem(
        systemImage: "text.bubble",
        title: "Friendly or Detailed Agents",
        detail: "Choose per bot from Chat Info whether it shows each step of its work or short updates."
      ),
      WhatsNewItem(
        systemImage: "mic",
        title: "Hold to Record",
        detail: "Hold the mic button to start a voice message right away.",
        platforms: .iOS
      ),
      WhatsNewItem(
        systemImage: "photo.on.rectangle",
        title: "Swipe Through Media",
        detail: "Photos and videos open in a gallery you can swipe through.",
        platforms: .iOS
      ),
    ]
  )
}
