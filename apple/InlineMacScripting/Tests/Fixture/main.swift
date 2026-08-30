import AppKit
import InlineMacScripting

// Standalone automation fixture: no InlineKit, account, disk database, or network.
@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate {
  var selected: ScriptingValue = .missing

  func applicationWillFinishLaunching(_ notification: Notification) {
    FileHandle.standardError.write(Data("Fixture installing handler; command class linked: \(NSClassFromString("InlineScriptCommand") != nil)\n".utf8))
    InlineScripting.install { [self] request in
      FileHandle.standardError.write(Data("Fixture received: \(request)\n".utf8))
      switch request {
      case .show: return .boolean(true)
      case .account: return .record([.userID: .text("9223372036854775807"), .displayName: .text("Fixture 🦊"), .username: .text("fixture")])
      case .spaces: return .list([.record([.spaceID: .text("7"), .title: .text("Fixture space")])])
      case let .chats(query, _, _, _):
        if query == "failure" { throw ScriptingError(-10004, "Fixture account unavailable.") }
        if query == "empty" { return .list([]) }
        return .list([chat("42")])
      case .currentChat: return selected
      case let .openChat(id): selected = chat(String(id)); return .text(String(id))
      case let .messages(id, _, _):
        return .list([.record([.chatID: .text(String(id)), .messageID: .text("99"), .text: .text("Hello 🦊"), .sentAt: .seconds(1_700_000_000), .outgoing: .boolean(false), .senderID: .text("7")])])
      case let .send(_, id, requestID):
        try await Task.sleep(for: .milliseconds(20))
        return .record([.chatID: .text(String(id)), .messageID: .text("100"), .requestID: .text(String(requestID))])
      case let .link(id): return .text("in://chat/\(id)")
      }
    }
  }

  private func chat(_ id: String) -> ScriptingValue {
    .record([.chatID: .text(id), .title: .text("Fixture chat"), .kind: .text("thread"), .spaceID: .text("7"), .unreadCount: .integer(2)])
  }
}

let app = NSApplication.shared
let delegate = FixtureDelegate()
app.delegate = delegate
app.setActivationPolicy(.prohibited)
app.run()
