extension WhatsNewAnnouncement {
  /// Shown once after updating to a build that carries it. Set to nil for releases
  /// that don't need one, and give each new announcement a new id.
  public static let current: WhatsNewAnnouncement? = WhatsNewAnnouncement(
    id: "2026-10-27-highlights",
    items: [
      WhatsNewItem(
        systemImage: "pip",
        title: "Floating Call Pill",
        detail: "Your Grid room, mic, screen share, and leave stay within reach while you work in other apps.",
        platforms: .macOS
      ),
      WhatsNewItem(
        systemImage: "bell.badge",
        title: "Notifications Clear Everywhere",
        detail: "Read or delete a notification on one device and it clears on your others."
      ),
      WhatsNewItem(
        systemImage: "headphones",
        title: "Voice Messages Keep Playing",
        detail: "Switch chats or lock your phone. A playback bar lets you pause, change speed, or jump back.",
        platforms: .iOS
      ),
      WhatsNewItem(
        systemImage: "magnifyingglass",
        title: "Search Settings",
        detail: "Press Command-F in Settings to jump straight to any option.",
        platforms: .macOS
      ),
      WhatsNewItem(
        systemImage: "arrow.up.doc",
        title: "Send Files up to 500 MB",
        detail: "Files and videos can now be up to 500 MB, up from 200 MB."
      ),
      WhatsNewItem(
        systemImage: "waveform",
        title: "Send While Recording",
        detail: "Send or discard a voice message without stopping the recording first.",
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
        systemImage: "point.3.connected.trianglepath.dotted",
        title: "Sturdier Agents",
        detail: "Claude, Codex, and Hermes stay connected and recover from network and sign-in errors on their own."
      ),
    ]
  )
}
