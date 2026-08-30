import AppKit
import InlineMacScripting

// Standalone automation fixture: no InlineKit, account, disk database, or network.
@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate {
  var selected: ScriptingValue = .missing
  var reply: ScriptingValue = .missing

  func applicationWillFinishLaunching(_ notification: Notification) {
    FileHandle.standardError.write(Data("Fixture installing handler; command class linked: \(NSClassFromString("InlineScriptCommand") != nil)\n".utf8))
    InlineScripting.install { [self] request in
      FileHandle.standardError.write(Data("Fixture received: \(request)\n".utf8))
      switch request {
      case .show: return .boolean(true)
      case .account: return .record([.userID: .text("9223372036854775807"), .displayName: .text("Fixture 🦊"), .username: .text("fixture")])
      case .spaces: return .list([.record([.spaceID: .text("7"), .title: .text("Fixture space")])])
      case let .users(query, _, _, _): return .list(query == "empty" ? [] : [user("7")])
      case let .user(id): return user(String(id))
      case .searchUsers: return .list([user("7")])
      case let .chats(query, _, _, _):
        if query == "failure" { throw ScriptingError(-10004, "Fixture account unavailable.") }
        if query == "empty" { return .list([]) }
        return .list([chat("42")])
      case .currentChat: return selected
      case .currentSelection: return reply == .missing ? selected : reply
      case let .createThread(title, spaceID, participantIDs, isPublic):
        if title == "Fixture workflow" {
          guard spaceID == 7, participantIDs == [7, Int64.max], !isPublic else { throw ScriptingError.failed }
        } else if title == "Public fixture" {
          guard spaceID == 7, participantIDs.isEmpty, isPublic else { throw ScriptingError.failed }
        }
        return chat(isPublic ? "44" : "43")
      case let .openChat(id):
        // Synthetic route with a primary conversation and an open reply pane.
        selected = chat(id == 88 ? "42" : String(id))
        reply = id == 88 ? chat("88", title: "Reply [review] 🦊") : .missing
        return .text(String(id))
      case let .messages(id, _, _):
        return .list([.record([.chatID: .text(String(id)), .messageID: .text("99"), .text: .text("Hello 🦊"), .sentAt: .seconds(1_700_000_000), .outgoing: .boolean(false), .senderID: .text("7")])])
      case let .send(text, id, requestID):
        if id == 43, text != "**Hello** [@Fixture](inline://user/7)." { throw ScriptingError.failed }
        try await Task.sleep(for: .milliseconds(20))
        return .record([.chatID: .text(String(id)), .messageID: .text("100"), .requestID: .text(String(requestID))])
      case let .link(id): return .text("in://chat/\(id)")
      }
    }
  }

  private func chat(_ id: String, title: String = "Fixture chat") -> ScriptingValue {
    let url = URL(string: "in://chat/\(id)")!
    return .record([
      .identifier: .text(id), .name: .text(title),
      .chatID: .text(id), .title: .text(title), .kind: .text("thread"), .spaceID: .text("7"), .unreadCount: .integer(2),
      .url: .text(url.absoluteString), .markdownLink: .text(ScriptingLink.markdown(title: title, url: url)),
    ])
  }

  private func user(_ id: String) -> ScriptingValue {
    .record([.userID: .text(id), .displayName: .text("Fixture 🦊"), .username: .text("fixture"), .isBot: .boolean(true)])
  }
}

let app = NSApplication.shared
let delegate = FixtureDelegate()
app.delegate = delegate
app.setActivationPolicy(.prohibited)
app.run()
