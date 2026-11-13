import Foundation
import Testing

@testable import InlineKit

@Suite("Chat row builder and diff")
struct ChatRowSnapshotTests {
  private static var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  /// 2026-01-01 00:00 UTC plus seconds.
  private static func at(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1_767_225_600 + seconds)
  }

  private static func message(
    _ messageId: Int64, globalId: Int64? = nil, at seconds: TimeInterval, from: Int64 = 2,
    out: Bool = false, text: String = "hi", status: MessageSendingStatus? = nil
  ) -> FullMessage {
    var message = Message(
      messageId: messageId, fromId: from, date: at(seconds), text: text,
      peerUserId: nil, peerThreadId: 1, chatId: 1, out: out, status: status
    )
    message.globalId = globalId ?? (messageId > 0 ? 1_000 + messageId : nil)
    return FullMessage(senderInfo: nil, message: message, reactions: [], repliedToMessage: nil, attachments: [])
  }

  private static func input(
    _ messages: [FullMessage], unread: ChatRowBuilder.UnreadLine? = nil, parent: FullMessage? = nil,
    collapsedMaxId: Int64? = nil, kind: ChatRowChatKind = .group, reachesOldest: Bool = false
  ) -> ChatRowBuilder.Input {
    .init(
      messages: messages, threadParent: parent, unreadLine: unread, collapsedMaxId: collapsedMaxId,
      chatKind: kind, reachesOldest: reachesOldest, calendar: utc
    )
  }

  private static func snapshot(
    _ input: ChatRowBuilder.Input, after previous: ChatRowSnapshot? = nil, reason: ChatRowReason = .refresh
  ) -> ChatRowSnapshot {
    let output = ChatRowBuilder.build(input)
    return .next(after: previous, rows: output.rows, reason: reason, coverage: .init(),
                 unreadLineMessageId: output.unreadLineMessageId)
  }

  private static func grouping(_ snapshot: ChatRowSnapshot, _ globalId: Int64) -> ChatRowGrouping? {
    guard case let .message(_, grouping)? = snapshot.row(for: .message(globalId))?.content else { return nil }
    return grouping
  }

  private static func describe(_ snapshot: ChatRowSnapshot) -> [String] {
    snapshot.rows.map { row in
      switch row.content {
        case let .message(message, _): "m\(message.message.messageId)"
        case let .threadParent(message): "parent\(message.message.messageId)"
        case .threadRepliesHeader: "replies"
        case .collapsedHistory: "collapsed"
        case let .daySeparator(day): "day\(Int(day.timeIntervalSince1970 - 1_767_225_600) / 86_400)"
        case .unreadLine: "unread"
        case .statusNotice: "notice"
      }
    }
  }

  // MARK: Builder

  @Test func `day separators start each day`() {
    let rows = Self.snapshot(Self.input([
      Self.message(1, at: 10), Self.message(2, at: 20), Self.message(3, at: 86_400 + 5),
    ]))
    #expect(Self.describe(rows) == ["day0", "m1", "m2", "day1", "m3"])
  }

  @Test func `unread line sits above the first unread message and above the day it starts`() {
    let messages = [
      Self.message(1, at: 10), Self.message(2, at: 20), Self.message(3, at: 30),
      Self.message(4, at: 86_400 + 5), Self.message(5, at: 86_400 + 10),
    ]
    let inside = Self.snapshot(Self.input(messages, unread: .init(boundary: 1)))
    #expect(Self.describe(inside) == ["day0", "m1", "unread", "m2", "m3", "day1", "m4", "m5"])
    #expect(inside.unreadLineMessageId == 2)
    let atDay = Self.snapshot(Self.input(messages, unread: .init(boundary: 3)))
    #expect(Self.describe(atDay) == ["day0", "m1", "m2", "m3", "unread", "day1", "m4", "m5"])
  }

  @Test func `unread line skips own messages, needs a read message, and can be removed`() {
    let messages = [Self.message(1, at: 10), Self.message(2, at: 20, out: true), Self.message(3, at: 30)]
    let line = Self.snapshot(Self.input(messages, unread: .init(boundary: 1)))
    #expect(Self.describe(line).firstIndex(of: "unread") == Self.describe(line).firstIndex(of: "m3")! - 1)
    // A window without any read message cannot place it unless it reaches the start.
    let noRead = Self.snapshot(Self.input(Array(messages.dropFirst()), unread: .init(boundary: 1)))
    #expect(!Self.describe(noRead).contains("unread"))
    let removed = Self.snapshot(Self.input(messages), after: line)
    #expect(!Self.describe(removed).contains("unread"))
    #expect(ChatRowDiff(from: line, to: removed).removals.map(\.id) == [.unreadLine])
  }

  @Test func `a pinned unread line stays put and moves on when its message leaves`() {
    let messages = [Self.message(1, at: 10), Self.message(2, at: 20), Self.message(3, at: 30)]
    let pinned = Self.snapshot(Self.input(messages, unread: .init(boundary: 1, pinnedMessageId: 2)))
    #expect(pinned.unreadLineMessageId == 2)
    // Reading more does not move it: the boundary is ignored once pinned.
    let later = Self.snapshot(Self.input(messages, unread: .init(boundary: 2, pinnedMessageId: 2)), after: pinned)
    #expect(ChatRowDiff(from: pinned, to: later).isEmpty)
    let deleted = Self.snapshot(
      Self.input([messages[0], messages[2]], unread: .init(boundary: 1, pinnedMessageId: 2)), after: later
    )
    #expect(Self.describe(deleted) == ["day0", "m1", "unread", "m3"])
  }

  @Test func `a pinned unread line shows only in a window that holds its boundary`() {
    let all = (1 ... 30).map { Self.message(Int64($0), at: TimeInterval($0) * 60) }
    let line = ChatRowBuilder.UnreadLine(boundary: 9, pinnedMessageId: 10)
    let pinnedWindow = Self.snapshot(Self.input(Array(all[4 ..< 15]), unread: line))
    #expect(pinnedWindow.unreadLineMessageId == 10)
    // A jump to a window entirely newer than the line: no line at its top.
    let newer = Self.snapshot(Self.input(Array(all[19 ..< 30]), unread: line), after: pinnedWindow)
    #expect(newer.unreadLineMessageId == nil)
    #expect(!Self.describe(newer).contains("unread"))
    // Entirely older: nothing at or after the line.
    let older = Self.snapshot(Self.input(Array(all[0 ..< 8]), unread: line), after: newer)
    #expect(older.unreadLineMessageId == nil)
    // Back to a window holding the boundary: the line returns above message 10.
    let back = Self.snapshot(Self.input(Array(all[6 ..< 20]), unread: line), after: older)
    #expect(back.unreadLineMessageId == 10)
    #expect(Self.describe(back)[Self.describe(back).firstIndex(of: "unread")! + 1] == "m10")
    // A window starting at the pinned message itself still shows it.
    let startsAtPin = Self.snapshot(Self.input(Array(all[9 ..< 20]), unread: line), after: back)
    #expect(startsAtPin.unreadLineMessageId == 10)
    // Starting just after a deleted pin at the chat's first message, it moves on.
    let fromStart = Self.snapshot(
      Self.input(Array(all[10 ..< 20]), unread: line, reachesOldest: true), after: startsAtPin
    )
    #expect(fromStart.unreadLineMessageId == 11)
  }

  @Test func `grouping follows sender, time and day`() {
    let rows = Self.snapshot(Self.input([
      Self.message(1, at: 10), Self.message(2, at: 70), Self.message(3, at: 500),
      Self.message(4, at: 510, from: 3), Self.message(5, at: 520, out: true),
    ]))
    let g1 = Self.grouping(rows, 1001), g2 = Self.grouping(rows, 1002), g3 = Self.grouping(rows, 1003)
    #expect(g1?.isFirstInGroup == true && g1?.isLastInGroup == false)
    #expect(g1?.showsSenderName == true && g1?.showsAvatar == true)
    #expect(g2?.isFirstInGroup == false && g2?.isLastInGroup == true && g2?.showsSenderName == false)
    // Seven minutes later starts a new group.
    #expect(g3?.isFirstInGroup == true && g3?.isLastInGroup == true)
    #expect(Self.grouping(rows, 1004)?.isFirstInGroup == true)
    let own = Self.grouping(rows, 1005)
    #expect(own?.showsAvatar == false && own?.showsSenderName == false)
  }

  @Test func `direct chats show no names or avatars`() {
    let rows = Self.snapshot(Self.input([Self.message(1, at: 10)], kind: .direct))
    #expect(Self.grouping(rows, 1001)?.showsSenderName == false)
    #expect(Self.grouping(rows, 1001)?.showsAvatar == false)
  }

  @Test func `a neighbour inserted or deleted changes only the rows whose grouping changed`() {
    let base = [Self.message(1, at: 10), Self.message(2, at: 20)]
    let before = Self.snapshot(Self.input(base))
    let inserted = Self.snapshot(Self.input(base + [Self.message(3, at: 30)]), after: before, reason: .liveAdd)
    let diff = ChatRowDiff(from: before, to: inserted)
    #expect(diff.insertions.map(\.id) == [.message(1003)])
    // m2 is no longer last in its group; m1 is unchanged.
    #expect(diff.updates.map(\.id) == [.message(1002)])
    #expect(inserted.row(for: .message(1001))?.revision == before.row(for: .message(1001))?.revision)
    let deleted = Self.snapshot(Self.input(base), after: inserted, reason: .delete)
    let back = ChatRowDiff(from: inserted, to: deleted)
    #expect(back.removals.map(\.id) == [.message(1003)])
    #expect(back.updates.map(\.id) == [.message(1002)])
  }

  @Test func `thread rows and collapsed history head the list`() {
    var parent = Self.message(7, at: 0)
    parent.message.chatId = 9
    parent.message.globalId = 77
    let rows = Self.snapshot(Self.input(
      [Self.message(1, at: 10), Self.message(2, at: 20), Self.message(3, at: 30)],
      parent: parent, collapsedMaxId: 2
    ))
    #expect(Self.describe(rows) == ["parent7", "replies", "collapsed", "day0", "m3"])
    #expect(rows.rows.first?.id == .threadParent(77))
  }

  @Test func `an acknowledged send keeps its row`() {
    let base = [Self.message(1, at: 10)]
    let pending = Self.message(-5, globalId: 50, at: 20, from: 1, out: true, status: .sending)
    let sent = Self.message(2, globalId: 50, at: 20, from: 1, out: true, status: .sent)
    let before = Self.snapshot(Self.input(base + [pending]), reason: .localSend)
    let after = Self.snapshot(Self.input(base + [sent]), after: before, reason: .sendAck)
    let diff = ChatRowDiff(from: before, to: after)
    #expect(before.ids == after.ids)
    #expect(diff.insertions.isEmpty && diff.removals.isEmpty && diff.moves.isEmpty)
    #expect(diff.updates.map(\.id) == [.message(50)])
  }

  @Test func `rows are sorted every time, so out-of-order adds and acks land in place`() {
    // The view model appends a late message at the end; the rows sort it.
    let appended = [Self.message(1, at: 10), Self.message(3, at: 30), Self.message(2, at: 20)]
    let rows = Self.snapshot(Self.input(appended))
    #expect(Self.describe(rows) == ["day0", "m1", "m2", "m3"])
    // An ack with an earlier server date moves the sent row before a newer message.
    let pending = Self.message(-5, globalId: 50, at: 40, from: 1, out: true, status: .sending)
    let before = Self.snapshot(Self.input(appended + [pending]))
    let acked = Self.message(4, globalId: 50, at: 25, from: 1, out: true, status: .sent)
    let after = Self.snapshot(Self.input(appended + [acked]), after: before, reason: .sendAck)
    #expect(Self.describe(after) == ["day0", "m1", "m2", "m4", "m3"])
    let diff = ChatRowDiff(from: before, to: after)
    #expect(diff.insertions.isEmpty && diff.removals.isEmpty)
    #expect(diff.moves.count == 1)
  }

  // MARK: Diff

  @Test func `an identical refresh is an empty diff`() {
    let messages = (1 ... 20).map { Self.message(Int64($0), at: TimeInterval($0) * 400) }
    let before = Self.snapshot(Self.input(messages, unread: .init(boundary: 5)))
    let after = Self.snapshot(Self.input(messages, unread: .init(boundary: 5)), after: before)
    #expect(after.revision == before.revision + 1)
    #expect(ChatRowDiff(from: before, to: after).isEmpty)
  }

  @Test func `an older page prepends and a newer page appends`() {
    let window = (11 ... 20).map { Self.message(Int64($0), at: TimeInterval($0) * 400) }
    let older = (1 ... 10).map { Self.message(Int64($0), at: TimeInterval($0) * 400) }
    let newer = (21 ... 23).map { Self.message(Int64($0), at: TimeInterval($0) * 400) }
    let before = Self.snapshot(Self.input(window))
    let prepended = Self.snapshot(Self.input(older + window), after: before, reason: .olderPage)
    let up = ChatRowDiff(from: before, to: prepended)
    #expect(up.insertions.map(\.id) == older.map { .message($0.id) })
    #expect(up.insertions.map(\.index) == Array(1 ... 10))
    #expect(up.removals.isEmpty && up.moves.isEmpty)
    // Paging leaves existing rows untouched.
    #expect(up.updates.isEmpty)
    let appended = Self.snapshot(Self.input(window + newer), after: before, reason: .newerPage)
    let down = ChatRowDiff(from: before, to: appended)
    #expect(down.insertions.map(\.id) == newer.map { .message($0.id) })
    #expect(down.updates.isEmpty)
  }

  @Test func `an edit updates one row`() {
    let messages = [Self.message(1, at: 10), Self.message(2, at: 900)]
    let before = Self.snapshot(Self.input(messages))
    let after = Self.snapshot(Self.input([messages[0], Self.message(2, at: 900, text: "edited")]), after: before)
    let diff = ChatRowDiff(from: before, to: after)
    #expect(diff.updates.map(\.id) == [.message(1002)])
    #expect(diff.insertions.isEmpty && diff.removals.isEmpty && diff.moves.isEmpty)
  }

  @Test func `a change hint gives the same diff as a full comparison`() {
    let messages = (1 ... 30).map { Self.message(Int64($0), at: TimeInterval($0) * 60) }
    let before = Self.snapshot(Self.input(messages))
    var edited = messages
    edited[29] = Self.message(30, at: 30 * 60, text: "streamed")
    edited.append(Self.message(31, at: 31 * 60))
    let output = ChatRowBuilder.build(Self.input(edited))
    let hinted = ChatRowSnapshot.next(
      after: before, rows: output.rows, reason: .liveUpdate, coverage: .init(), changedMessageIDs: [1030, 1031]
    )
    let full = ChatRowSnapshot.next(after: before, rows: output.rows, reason: .liveUpdate, coverage: .init())
    #expect(ChatRowDiff(from: before, to: hinted) == ChatRowDiff(from: before, to: full))
    #expect(ChatRowDiff(from: before, to: hinted).updates.map(\.id) == [.message(1030)])
  }

  @Test func `deleting a day's only message removes its separator`() {
    let messages = [Self.message(1, at: 10), Self.message(2, at: 86_400 + 10)]
    let before = Self.snapshot(Self.input(messages))
    let after = Self.snapshot(Self.input([messages[0]]), after: before, reason: .delete)
    let diff = ChatRowDiff(from: before, to: after)
    #expect(Set(diff.removals.map(\.id)) == [.message(1002), .daySeparator(Self.at(86_400))])
    #expect(diff.removals.map(\.index) == [2, 3])
  }

  @Test func `a first snapshot inserts every row`() {
    let rows = Self.snapshot(Self.input([Self.message(1, at: 10)]))
    let diff = ChatRowDiff(from: nil, to: rows)
    #expect(diff.insertions.count == rows.rows.count)
    #expect(rows.revision == 1)
  }
}
