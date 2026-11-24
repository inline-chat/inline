extension WhatsNewAnnouncement {
  /// Shown once after updating to a build that carries it. Set to nil for releases
  /// that don't need one, and give each new announcement a new id.
  public static let current: WhatsNewAnnouncement? = WhatsNewAnnouncement(
    id: "2026-11-24-highlights",
    items: [
      WhatsNewItem(
        systemImage: "list.bullet.rectangle",
        title: "A Faster Message List",
        detail: "Chats scroll more smoothly and open faster, with new animations for sending, reactions and new messages.",
        platforms: .iOS
      ),
      WhatsNewItem(
        systemImage: "magnifyingglass",
        title: "Search All Your Messages",
        detail: "Quick Search finds messages from every chat, and Command-F searches the one you're in.",
        platforms: .macOS
      ),
      WhatsNewItem(
        systemImage: "magnifyingglass",
        title: "Search All Your Messages",
        detail: "Search finds messages from every chat, even ones this device never loaded.",
        platforms: .iOS
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
        systemImage: "photo.stack",
        title: "Albums",
        detail: "Photos, videos and files you send together arrive as one album."
      ),
      WhatsNewItem(
        systemImage: "character.cursor.ibeam",
        title: "Select and Copy Across Messages",
        detail: "Drag to select text across messages, and paste it elsewhere with its formatting intact.",
        platforms: .macOS
      ),
      WhatsNewItem(
        systemImage: "textformat.size",
        title: "Text Size and Fonts",
        detail: "Use View › Make Text Bigger or Smaller, and pick fonts and line spacing in Appearance settings.",
        platforms: .macOS
      ),
      WhatsNewItem(
        systemImage: "checklist",
        title: "Agents You Can Act On",
        detail: "Approve plans and answer agents from cards, and choose per bot how much of their work you see."
      ),
      WhatsNewItem(
        systemImage: "mic",
        title: "Hold to Record",
        detail: "Hold the mic button to start a voice message right away.",
        platforms: .iOS
      ),
      WhatsNewItem(
        systemImage: "location.slash",
        title: "Photos Without Hidden Details",
        detail: "Photos and videos are sent without location or camera details. Turn on Original to send the untouched file."
      ),
    ]
  )
}
