import AppKit
import Testing
@testable import InlineMacScripting

@Suite struct ScriptingArgumentTests {
  @Test func dictionaryCommandCodesAreUniqueAndDispatchable() throws {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let xml = try XMLDocument(contentsOf: package.appendingPathComponent("Resources/Inline.sdef"))
    let commands = try xml.nodes(forXPath: "//command")
    let codes = commands.compactMap { ($0 as? XMLElement)?.attribute(forName: "code")?.stringValue }
    #expect(codes.count == 17)
    #expect(Set(codes).count == 17)
    for code in codes {
      #expect(code.utf8.count == 8)
      #expect(code.hasPrefix("Inln"))
      guard code.utf8.count == 8 else { continue }
      _ = try ScriptingRequest.decode(code: fourCC(String(code.suffix(4))), direct: "42", arguments: ["chatID": "42"])
    }
  }

  @Test func stableIDsPreserveAll64Bits() throws {
    #expect(try ScriptingRequest.decode(code: fourCC("open"), direct: "9223372036854775807", arguments: [:]) == .openChat(Int64.max))
  }

  @Test func selectionAndThreadTerminology() throws {
    #expect(try ScriptingRequest.decode(code: fourCC("cthr"), direct: nil, arguments: [:]) == .currentChat)
    #expect(try ScriptingRequest.decode(code: fourCC("csel"), direct: nil, arguments: [:]) == .currentSelection)
  }

  @Test(arguments: ["0", "-1", "1.5", " 1", "١", "9223372036854775808", ""])
  func invalidIDsAreRejected(_ value: String) {
    #expect(throws: ScriptingError.self) {
      try ScriptingRequest.decode(code: fourCC("open"), direct: value, arguments: [:])
    }
  }

  @Test func missingAndNumericIDsAreRejected() {
    #expect(throws: ScriptingError.self) {
      try ScriptingRequest.decode(code: fourCC("open"), direct: nil, arguments: [:])
    }
    #expect(throws: ScriptingError.self) {
      try ScriptingRequest.decode(code: fourCC("open"), direct: NSNumber(value: Int64.max), arguments: [:])
    }
  }

  @Test func defaultsAndPagination() throws {
    #expect(try ScriptingRequest.decode(code: fourCC("msgs"), direct: "42", arguments: [:]) == .messages(chatID: 42, limit: 20, before: nil))
    #expect(try ScriptingRequest.decode(code: fourCC("find"), direct: "%_", arguments: ["spaceID": "7", "limit": 50, "offset": 100]) == .chats(query: "%_", spaceID: 7, limit: 50, offset: 100))
    #expect(try ScriptingRequest.decode(code: fourCC("msgs"), direct: "42", arguments: ["beforeID": "99"]) == .messages(chatID: 42, limit: 20, before: 99))
  }

  @Test func badBoundsAndBooleansAreRejected() {
    for value: Any in [0, -1, 101, 1.5, true, "20"] {
      #expect(throws: ScriptingError.self) {
        try ScriptingRequest.decode(code: fourCC("msgs"), direct: "1", arguments: ["limit": value])
      }
    }
  }

  @Test func sendRequiresExplicitDestinationAndPreservesText() throws {
    #expect(try ScriptingRequest.decode(code: fourCC("send"), direct: " Hello 🦊\n", arguments: ["chatID": "2", "requestID": "9223372036854775807"]) == .send(text: " Hello 🦊\n", chatID: 2, requestID: Int64.max))
    for text in [" ", String(repeating: "🦊", count: 2049)] {
      #expect(throws: ScriptingError.self) {
        try ScriptingRequest.decode(code: fourCC("send"), direct: text, arguments: ["chatID": "2"])
      }
    }
    #expect(throws: ScriptingError.self) {
      try ScriptingRequest.decode(code: fourCC("send"), direct: "hello", arguments: [:])
    }
  }

  @Test func userLookupScopesAndBounds() throws {
    #expect(try ScriptingRequest.decode(code: fourCC("usrs"), direct: nil, arguments: [:]) == .users(query: nil, spaceID: nil, limit: 100, offset: 0))
    #expect(try ScriptingRequest.decode(code: fourCC("ufnd"), direct: " @Maya ", arguments: ["spaceID": "7", "limit": 4, "offset": 2]) == .users(query: "Maya", spaceID: 7, limit: 4, offset: 2))
    #expect(try ScriptingRequest.decode(code: fourCC("uinf"), direct: "9223372036854775807", arguments: [:]) == .user(Int64.max))
    #expect(try ScriptingRequest.decode(code: fourCC("usrh"), direct: "@maya", arguments: [:]) == .searchUsers(query: "maya", limit: 20))
    #expect(throws: ScriptingError.self) { try ScriptingRequest.decode(code: fourCC("usrh"), direct: "maya", arguments: ["limit": 21]) }
    #expect(throws: ScriptingError.self) { try ScriptingRequest.decode(code: fourCC("ufnd"), direct: "@", arguments: [:]) }
  }

  @Test func privateThreadCreationPreservesAndDeduplicatesParticipantIDs() throws {
    #expect(try ScriptingRequest.decode(code: fourCC("crth"), direct: nil, arguments: [:]) == .createThread(title: nil, spaceID: nil, participantIDs: [], isPublic: false))
    #expect(try ScriptingRequest.decode(code: fourCC("crth"), direct: " Review ", arguments: ["spaceID": "7", "participantIDs": ["42", "9223372036854775807", "42"]]) == .createThread(title: "Review", spaceID: 7, participantIDs: [42, Int64.max], isPublic: false))
    for value: Any in ["42", [42], ["0"], Array(repeating: "42", count: 101)] {
      #expect(throws: ScriptingError.self) { try ScriptingRequest.decode(code: fourCC("crth"), direct: nil, arguments: ["participantIDs": value]) }
    }
    #expect(throws: ScriptingError.self) { try ScriptingRequest.decode(code: fourCC("crth"), direct: String(repeating: "🦊", count: 76), arguments: [:]) }
  }

  @Test func publicThreadsRequireExplicitSpaceAndNoParticipants() throws {
    #expect(try ScriptingRequest.decode(code: fourCC("crth"), direct: "Public", arguments: ["spaceID": "7", "isPublic": true]) == .createThread(title: "Public", spaceID: 7, participantIDs: [], isPublic: true))
    for arguments: [String: Any] in [
      ["isPublic": true], ["spaceID": "7", "isPublic": true, "participantIDs": ["42"]],
      ["spaceID": "7", "isPublic": 1], ["spaceID": "7", "isPublic": "true"],
    ] {
      #expect(throws: ScriptingError.self) { try ScriptingRequest.decode(code: fourCC("crth"), direct: "Public", arguments: arguments) }
    }
  }
}

@Suite struct ScriptingResultTests {
  @Test func markdownLinksEscapeTitlesWithoutChangingIdentity() throws {
    let url = try #require(URL(string: "in://chat/9223372036854775807"))
    let title = "R&D [plan] (v2) \\ *ship* _now_ <img> `code` 🚀\r\nnext"
    let link = ScriptingLink.markdown(title: title, url: url)
    #expect(link == #"[R\&D \[plan\] \(v2\) \\ \*ship\* \_now\_ \<img\> \`code\` 🚀 next](in://chat/9223372036854775807)"#)
    #expect(ScriptingLink.markdown(title: "Renamed", url: url) == "[Renamed](in://chat/9223372036854775807)")
    let record = ScriptingValue.record([
      .chatID: .text(String(Int64.max)), .title: .text(title), .url: .text(url.absoluteString), .markdownLink: .text(link),
    ]).descriptor()
    #expect(record.forKeyword(fourCC("pURL"))?.stringValue == url.absoluteString)
    #expect(record.forKeyword(fourCC("Imlk"))?.stringValue == link)
    #expect(record.forKeyword(fourCC("Itit"))?.stringValue == title)
  }

  @Test func nativeRecordsListsAndMissingValue() {
    let descriptor = ScriptingValue.list([.record([
      .chatID: .text("9223372036854775807"), .unreadCount: .integer(3),
      .outgoing: .boolean(true), .sentAt: .seconds(1_700_000_000), .text: .text("Hello 🦊"),
    ])]).descriptor()
    #expect(descriptor.numberOfItems == 1)
    let record = descriptor.atIndex(1)
    #expect(record?.forKeyword(fourCC("Icid"))?.stringValue == "9223372036854775807")
    #expect(record?.forKeyword(fourCC("Iunr"))?.int32Value == 3)
    #expect(record?.forKeyword(fourCC("Iout"))?.booleanValue == true)
    #expect(record?.forKeyword(fourCC("Itxt"))?.stringValue == "Hello 🦊")
    #expect(ScriptingValue.missing.descriptor().typeCodeValue == fourCC("msng"))
  }
}

@Suite @MainActor struct ScriptingExecutionTests {
  @Test func replyWaitsForCompletion() async throws {
    var results: [Result<ScriptingValue, ScriptingError>] = []
    let execution = ScriptExecution { results.append($0) }
    execution.start(request: .account) { _ in
      try await Task.sleep(for: .milliseconds(10))
      return .text("ready")
    }
    #expect(results.isEmpty)
    try await Task.sleep(for: .milliseconds(60))
    #expect(results == [.success(.text("ready"))])
  }

  @Test(.timeLimit(.minutes(1)))
  func timedOutHandlersKeepCapacityUntilTheyExit() async throws {
    var results: [Result<ScriptingValue, ScriptingError>] = []
    var suspended: [CheckedContinuation<ScriptingValue, Never>] = []
    let (replies, replied) = AsyncStream<Void>.makeStream()
    let (completions, completed) = AsyncStream<Void>.makeStream()
    InlineScripting.install { _ in
      await withCheckedContinuation { suspended.append($0) }
    }

    for _ in 0 ..< 16 {
      let handler = try InlineScripting.begin()
      let execution = ScriptExecution {
        results.append($0)
        replied.yield()
      }
      execution.start(request: .account, timeout: .milliseconds(10)) { request in
        defer { completed.yield() }
        return try await handler(request)
      }
    }
    var replyIterator = replies.makeAsyncIterator()
    for _ in 0 ..< 16 { await replyIterator.next() }
    #expect(results == Array(repeating: .failure(.timeout), count: 16))
    #expect(suspended.count == 16)
    #expect(throws: ScriptingError.self) { try InlineScripting.begin() }

    // Continuations remain suspended after cancellation, unlike cancellable sleep.
    for continuation in suspended { continuation.resume(returning: .text("too late")) }
    var completionIterator = completions.makeAsyncIterator()
    for _ in 0 ..< 16 { await completionIterator.next() }
    #expect(results.count == 16)

    InlineScripting.install { _ in .boolean(true) }
    let nextHandler = try InlineScripting.begin()
    #expect(try await nextHandler(.show) == .boolean(true))
  }

  @Test func unexpectedErrorsDoNotExposeImplementationDetails() async throws {
    var result: Result<ScriptingValue, ScriptingError>?
    let execution = ScriptExecution { result = $0 }
    execution.start(request: .account) { _ in
      throw NSError(domain: "private SQL and paths", code: 1)
    }
    try await Task.sleep(for: .milliseconds(30))
    #expect(result == .failure(.failed))
  }

  @Test func creationTimeoutWarnsAgainstDuplicateThreads() async {
    let result: Result<ScriptingValue, ScriptingError> = await withCheckedContinuation { continuation in
      let execution = ScriptExecution { continuation.resume(returning: $0) }
      execution.start(request: .createThread(title: nil, spaceID: nil, participantIDs: [], isPublic: false), timeout: .milliseconds(10)) { _ in
        try await Task.sleep(for: .seconds(1))
        return .missing
      }
    }
    #expect(result == .failure(.creationOutcomeUnknown))
  }
}
